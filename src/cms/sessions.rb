require "digest"
require "securerandom"
require "time"

require_relative "storage"

module Cms
  module Sessions
    COLLECTION_FILE = "sessions.json"

    IDLE_TTL = 30 * 60          # sliding inactivity window (seconds)
    ABSOLUTE_TTL = 8 * 60 * 60  # hard cap measured from login (seconds)
    EXTEND_THRESHOLD = 60       # only persist a slide worth writing (seconds)

    def self.hash_token(token)
      Digest::SHA256.hexdigest(token)
    end

    def self.iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
    end

    def self.parse(value)
      Time.iso8601(value)
    end

    # Issues a session. The raw token is returned exactly once; the store keeps
    # only its SHA-256 hash, the account, the absolute expiry and the sliding idle
    # expiry.
    def self.create_session(account_id)
      Cms::Storage.with_lock do
        token = SecureRandom.hex(32)
        sessions = Cms::Storage.read_collection(COLLECTION_FILE)
        now = Time.now.utc
        session = {
          "tokenHash" => hash_token(token),
          "accountId" => account_id,
          "createdAt" => iso(now),
          "expiresAt" => iso(now + ABSOLUTE_TTL),
          "idleExpiresAt" => iso(now + IDLE_TTL),
        }
        sessions << session
        Cms::Storage.write_collection(COLLECTION_FILE, sessions)
        { "token" => token, "expiresAt" => session["expiresAt"] }
      end
    end

    # Resolves a raw token to its live session, or nil if unknown or expired. An
    # expired session is dropped. On success the idle window slides forward (capped
    # at the absolute expiry) and is persisted only when the move is large enough,
    # so authenticated reads do not write on every request.
    def self.resolve_session(token)
      Cms::Storage.with_lock do
        token_hash = hash_token(token)
        sessions = Cms::Storage.read_collection(COLLECTION_FILE)
        now = Time.now.utc
        index = sessions.index { |s| s["tokenHash"] == token_hash }
        return nil if index.nil?

        session = sessions[index]
        absolute = parse(session["expiresAt"])
        idle = parse(session["idleExpiresAt"])
        if now >= absolute || now >= idle
          sessions.delete_at(index)
          Cms::Storage.write_collection(COLLECTION_FILE, sessions)
          return nil
        end

        next_idle = [now + IDLE_TTL, absolute].min
        if next_idle - idle > EXTEND_THRESHOLD
          session["idleExpiresAt"] = iso(next_idle)
          Cms::Storage.write_collection(COLLECTION_FILE, sessions)
        end
        { "accountId" => session["accountId"], "expiresAt" => session["expiresAt"] }
      end
    end

    # Logout / revocation: deletes the session and takes effect immediately.
    def self.delete_session(token)
      Cms::Storage.with_lock do
        token_hash = hash_token(token)
        sessions = Cms::Storage.read_collection(COLLECTION_FILE)
        remaining = sessions.reject { |s| s["tokenHash"] == token_hash }
        removed = remaining.length != sessions.length
        Cms::Storage.write_collection(COLLECTION_FILE, remaining) if removed
        removed
      end
    end
  end
end
