require "minitest/autorun"
require "json"
require "net/http"
require "uri"
require "cgi"
require "securerandom"
require "socket"
require "tmpdir"
require "fileutils"
require "rbconfig"

SRC = File.expand_path("../src", __dir__)
require File.join(SRC, "cms/validation")
require File.join(SRC, "cms/account")
require File.join(SRC, "cms/access")
require File.join(SRC, "cms/models/blog_posting")
require File.join(SRC, "cms/models/person")
require File.join(SRC, "cms/models/organization")
require File.join(SRC, "cms/models/web_page")
require File.join(SRC, "cms/models/image_object")
require File.join(SRC, "cms/models/video_object")
require File.join(SRC, "cms/models/audio_object")
require File.join(SRC, "cms/models/category_code")
require File.join(SRC, "cms/models/category_code_set")
require File.join(SRC, "cms/models/defined_term")
require File.join(SRC, "cms/models/defined_term_set")
require File.join(SRC, "cms/models/comment")
require File.join(SRC, "cms/models/web_site")
require File.join(SRC, "cms/models/site_navigation_element")

# Shared test harness. Spawns the generated server as a subprocess against a fresh
# temp data dir and drives it over HTTP. Auth is mandatory on writes, so the entity
# suite runs as an admin (who may do everything) and the CRUD contract is exercised
# unchanged. The active bearer token is module scoped so request helpers attach it
# without threading it through every call.
module T
  MODELS = {
      "BlogPosting" => Cms::Models::BlogPosting,
      "Person" => Cms::Models::Person,
      "Organization" => Cms::Models::Organization,
      "WebPage" => Cms::Models::WebPage,
      "ImageObject" => Cms::Models::ImageObject,
      "VideoObject" => Cms::Models::VideoObject,
      "AudioObject" => Cms::Models::AudioObject,
      "CategoryCode" => Cms::Models::CategoryCode,
      "CategoryCodeSet" => Cms::Models::CategoryCodeSet,
      "DefinedTerm" => Cms::Models::DefinedTerm,
      "DefinedTermSet" => Cms::Models::DefinedTermSet,
      "Comment" => Cms::Models::Comment,
      "WebSite" => Cms::Models::WebSite,
      "SiteNavigationElement" => Cms::Models::SiteNavigationElement,
  }.freeze
  READONLY_FIELDS = Cms::Access::READONLY_FIELDS

  SERVER_PATH = File.join(SRC, "server.rb")
  DEFAULT_ADMIN = { "username" => "admin", "password" => "bootstrap-admin-secret", "role" => "admin" }.freeze

  SCALAR_SAMPLES = {
    "Text" => "sample text",
    "Integer" => 42,
    "Number" => 3.14,
    "Boolean" => true,
    "Date" => "2026-05-19T00:00:00Z",
    "DateTime" => "2026-05-19T12:00:00Z",
    "Time" => "2026-05-19T12:00:00Z",
    "URL" => "https://example.com/resource",
  }.freeze

  @auth_token = nil
  @shared = nil

  def self.set_auth_token(token)
    @auth_token = token
  end

  def self.free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def self.account_record(spec)
    { "id" => SecureRandom.uuid, "username" => spec["username"], "passwordHash" => Cms::Account.hash_password(spec["password"]), "role" => spec["role"] }
  end

  # A running server instance backed by its own temp data dir and subprocess.
  class Server
    attr_reader :port, :data_dir, :base_url, :token

    def initialize(accounts: nil, env: nil)
      @port = T.free_port
      @data_dir = Dir.mktmpdir("cms-test-rb-")
      seed = accounts
      seed = [T::DEFAULT_ADMIN] if seed.nil? && env.nil?
      unless seed.nil?
        File.write(File.join(@data_dir, "accounts.json"), JSON.pretty_generate(seed.map { |a| T.account_record(a) }))
      end

      # Default the rate limits high so the conformance suite never trips them — all
      # requests share one process and one loopback IP. The rate-limit suite sets
      # small values through env to exercise the limiter on purpose.
      proc_env = { "PORT" => @port.to_s, "DATA_DIR" => @data_dir,
                   "RATE_LIMIT_READ_PER_MINUTE" => "1000000", "RATE_LIMIT_WRITE_PER_MINUTE" => "1000000" }
      proc_env.merge!(env) if env
      @pid = Process.spawn(proc_env, RbConfig.ruby, T::SERVER_PATH, out: File::NULL, err: File::NULL)
      @base_url = "http://127.0.0.1:#{@port}"
      wait_for_health

      admin = (seed || []).find { |a| a["role"] == "admin" }
      @token = admin ? T.login(self, admin["username"], admin["password"]) : nil
    end

    def wait_for_health
      deadline = Time.now + 10
      while Time.now < deadline
        begin
          res = Net::HTTP.get_response(URI(@base_url + "/health"))
          return if res.code.to_i == 200
        rescue StandardError
          nil
        end
        sleep 0.05
      end
      stop
      raise "Server did not become healthy within 10s"
    end

    def stop
      return if @stopped
      @stopped = true
      begin
        Process.kill("TERM", @pid)
        Process.wait(@pid)
      rescue StandardError
        nil
      end
      FileUtils.remove_entry(@data_dir, true)
    end
  end

  def self.start_server(accounts: nil, env: nil)
    Server.new(accounts: accounts, env: env)
  end

  def self.get_server
    if @shared.nil?
      @shared = Server.new
      shared = @shared
      Minitest.after_run { shared.stop }
    end
    # Re-bind the active token on every call: other suites (auth conformance) point
    # the module token at their own server; the entity suite re-binds it here.
    @auth_token = @shared.token
    @shared
  end

  def self.login(server, username, password)
    r = request_json(server, "POST", "/auth/login", { "username" => username, "password" => password }, no_auth: true)
    raise "login(#{username}) failed with #{r["status"]}: #{r["raw"]}" if r["status"] != 200
    r["body"]["token"]
  end

  def self.plural(entity)
    entity.gsub(/([A-Z])/) { "-#{$1}" }.sub(/\A-/, "").downcase + "s"
  end

  def self.sample_one(spec)
    case spec["kind"]
    when "scalar"
      SCALAR_SAMPLES.fetch(spec["type"], "sample")
    when "enum"
      spec["values"][0]
    when "embed"
      { "@type" => spec["type"], "alternateName" => "en" }
    else
      raise "sample_one cannot handle kind #{spec["kind"]}"
    end
  end

  # Gives each build a distinct value for a unique-key string field, so the second
  # create in any multi-record test does not trip duplicate detection.
  def self.unique_value(type, base)
    suffix = SecureRandom.hex(16)
    type == "URL" ? "#{base}/#{suffix}" : "#{base}-#{suffix}"
  end

  def self.make_dep(server, entity)
    payload = build_payload(server, entity)
    r = request_json(server, "POST", "/" + plural(entity), payload)
    raise "make_dep(#{entity}) failed with #{r["status"]}: #{r["raw"]}" if r["status"] != 201
    r["body"]["id"]
  end

  # Builds a valid payload. System and internal fields (READONLY_FIELDS) are never
  # sent — they are not client writable and would be rejected with 400.
  def self.build_payload(server, entity, partial: false)
    mod = MODELS[entity]
    key = mod::UNIQUE_KEY
    payload = {}
    mod::FIELDS.each do |name, spec|
      next if READONLY_FIELDS.include?(name)
      next if !partial && !mod::REQUIRED_FIELDS.include?(name)
      if spec["kind"] == "ref"
        value = make_dep(server, spec["targets"][0])
      else
        value = sample_one(spec)
        value = unique_value(spec["type"], value) if key.include?(name) && spec["kind"] == "scalar" && value.is_a?(String)
      end
      payload[name] = spec["cardinality"] == "many" ? [value] : value
    end
    payload
  end

  def self.post_entity(server, entity, payload)
    request_json(server, "POST", "/" + plural(entity), payload)
  end

  def self.request_json(server, method, path, body = nil, headers: nil, raw_body: nil, no_auth: false)
    uri = URI(server.base_url + path)
    klass = {
      "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put,
      "DELETE" => Net::HTTP::Delete, "OPTIONS" => Net::HTTP::Options
    }.fetch(method)
    req = klass.new(uri)
    req["Accept"] = "application/json"
    # Attach the active bearer token unless opted out or the caller set their own
    # Authorization header (caller headers win on conflict).
    req["Authorization"] = "Bearer #{@auth_token}" if !no_auth && !@auth_token.nil?
    if !raw_body.nil?
      req.body = raw_body.is_a?(String) ? raw_body : raw_body.to_s
      req["Content-Type"] = "application/json"
    elsif !body.nil?
      req.body = JSON.generate(body)
      req["Content-Type"] = "application/json"
    end
    (headers || {}).each { |k, v| req[k] = v }
    res = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 10, read_timeout: 10) { |http| http.request(req) }
    raw = res.body
    parsed = nil
    if raw && !raw.empty?
      begin
        parsed = JSON.parse(raw)
      rescue JSON::ParserError
        parsed = nil
      end
    end
    headers_lc = {}
    res.each_header { |k, v| headers_lc[k.downcase] = v }
    { "status" => res.code.to_i, "headers" => headers_lc, "body" => parsed, "raw" => raw || "" }
  end
end
