# Per-IP sliding-window rate limiter. Two independent one-minute windows per
# client: reads (GET/HEAD and any non-write method) and writes (POST/PUT/DELETE).
# State lives in process memory, matching the long-running single-process model
# (like Node, Python, Java) — counts are not shared across instances. An
# X-Forwarded-For header is never consulted; the peer address of the connection is
# the only trusted source. The server is threaded, so all access to the shared
# state is guarded by a lock.

module Cms
  module RateLimit
    WINDOW_SECONDS = 60
    WRITE_METHODS = ["POST", "PUT", "DELETE"].freeze

    def self.limit_from_env(name, fallback)
      raw = ENV[name]
      return fallback if raw.nil? || raw.empty?
      begin
        value = Integer(raw)
      rescue ArgumentError
        return fallback
      end
      value > 0 ? value : fallback
    end

    READ_LIMIT = limit_from_env("RATE_LIMIT_READ_PER_MINUTE", 600)
    WRITE_LIMIT = limit_from_env("RATE_LIMIT_WRITE_PER_MINUTE", 60)

    # ip -> { "read" => [timestamps], "write" => [timestamps] } still within the window.
    @hits = {}
    @lock = Mutex.new
    @last_sweep = 0.0

    def self.prune(stamps, cutoff)
      i = 0
      n = stamps.length
      i += 1 while i < n && stamps[i] <= cutoff
      stamps.shift(i) if i > 0
    end

    # Drop aged-out timestamps across all clients and forget idle ones, so memory
    # stays bounded by the clients active in the last window. Runs at most once per
    # window, piggybacked on a request under the lock — no background thread.
    def self.sweep(now, cutoff)
      return if now - @last_sweep < WINDOW_SECONDS
      @last_sweep = now
      @hits.keys.each do |ip|
        entry = @hits[ip]
        prune(entry["read"], cutoff)
        prune(entry["write"], cutoff)
        @hits.delete(ip) if entry["read"].empty? && entry["write"].empty?
      end
    end

    # Records a request from ip with the given method. Returns nil when the request
    # is within its bucket's limit, otherwise the whole seconds until the oldest
    # in-window request expires (at least 1) — the Retry-After value.
    def self.check(ip, method)
      bucket = WRITE_METHODS.include?(method) ? "write" : "read"
      limit = bucket == "write" ? WRITE_LIMIT : READ_LIMIT
      now = Time.now.to_f
      cutoff = now - WINDOW_SECONDS
      @lock.synchronize do
        sweep(now, cutoff)
        entry = @hits[ip]
        if entry.nil?
          entry = { "read" => [], "write" => [] }
          @hits[ip] = entry
        end
        stamps = entry[bucket]
        prune(stamps, cutoff)
        if stamps.length >= limit
          return [1, (stamps[0] + WINDOW_SECONDS - now).ceil].max
        end
        stamps.push(now)
        return nil
      end
    end
  end
end
