require "socket"
require "json"

require_relative "cms/http"
require_relative "cms/errors"
require_relative "cms/storage"
require_relative "cms/validation"
require_relative "cms/rate_limit"
require_relative "cms/access"
require_relative "cms/sessions"
require_relative "cms/account"
require_relative "cms/auth"
require_relative "cms/auth_router"
require_relative "cms/models/blog_posting"
require_relative "cms/models/person"
require_relative "cms/models/organization"
require_relative "cms/models/web_page"
require_relative "cms/models/image_object"
require_relative "cms/models/video_object"
require_relative "cms/models/audio_object"
require_relative "cms/models/category_code"
require_relative "cms/models/category_code_set"
require_relative "cms/models/defined_term"
require_relative "cms/models/defined_term_set"
require_relative "cms/models/comment"
require_relative "cms/models/web_site"
require_relative "cms/models/site_navigation_element"
require_relative "cms/routers/blog_posting"
require_relative "cms/routers/person"
require_relative "cms/routers/organization"
require_relative "cms/routers/web_page"
require_relative "cms/routers/image_object"
require_relative "cms/routers/video_object"
require_relative "cms/routers/audio_object"
require_relative "cms/routers/category_code"
require_relative "cms/routers/category_code_set"
require_relative "cms/routers/defined_term"
require_relative "cms/routers/defined_term_set"
require_relative "cms/routers/comment"
require_relative "cms/routers/web_site"
require_relative "cms/routers/site_navigation_element"

module Cms
  module Server
    ROUTERS = [
      Cms::Routers::BlogPosting,
      Cms::Routers::Person,
      Cms::Routers::Organization,
      Cms::Routers::WebPage,
      Cms::Routers::ImageObject,
      Cms::Routers::VideoObject,
      Cms::Routers::AudioObject,
      Cms::Routers::CategoryCode,
      Cms::Routers::CategoryCodeSet,
      Cms::Routers::DefinedTerm,
      Cms::Routers::DefinedTermSet,
      Cms::Routers::Comment,
      Cms::Routers::WebSite,
      Cms::Routers::SiteNavigationElement,
    ].freeze

    def self.peer_ip(socket)
      socket.peeraddr(false)[3]
    rescue StandardError
      "127.0.0.1"
    end

    def self.keep_alive?(req)
      (req.header("connection") || "").downcase != "close"
    end

    # Resolve a request to a Response. Rate limiting runs first so every request
    # counts against the per-IP window; the peer address is the only trusted
    # source. Auth resolves the principal before routing; a presented but invalid
    # credential is 401, no credential is the anonymous one.
    def self.dispatch(req)
      method = req.method
      path = req.path
      request_path = "#{method} #{path}"
      begin
        retry_after = Cms::RateLimit.check(req.client_ip, method)
        unless retry_after.nil?
          return Cms::Http.json_error(req, Cms::Errors.too_many_requests(request_path), { "Retry-After" => retry_after.to_s })
        end
        return Cms::Http.json_error(req, Cms::Errors.route_not_found(request_path)) if method == "TRACE" || method == "CONNECT"
        return Cms::Http.preflight if method == "OPTIONS"
        return Cms::Http.json_response(req, 200, { "status" => "ok" }) if method == "GET" && path == "/health"

        principal = Cms::Auth.resolve_principal(req)

        if path == "/auth" || path.start_with?("/auth/")
          resp = Cms::AuthRouter.handle(req, method, path, request_path, principal)
          return resp unless resp.nil?
        end

        # Writes require a session — no role grants anonymous writes (401, not 403).
        if Cms::Auth.requires_session?(method, principal)
          return Cms::Http.json_error(req, Cms::Errors.unauthorized(request_path))
        end

        ROUTERS.each do |router|
          resp = router.handle(req, method, path, request_path, principal)
          return resp unless resp.nil?
        end
        Cms::Http.json_error(req, Cms::Errors.route_not_found(request_path))
      rescue Cms::Auth::UnauthorizedError
        Cms::Http.json_error(req, Cms::Errors.unauthorized(request_path))
      rescue Cms::Http::BodyTooLargeError
        Cms::Http.json_error(req, Cms::Errors.payload_too_large(request_path))
      rescue Cms::Http::UnsupportedMediaTypeError
        Cms::Http.json_error(req, Cms::Errors.unsupported_media_type(request_path))
      rescue Cms::Errors::DuplicateError => e
        Cms::Http.json_error(req, Cms::Errors.validation(e.details, request_path))
      rescue JSON::ParserError
        Cms::Http.json_error(req, Cms::Errors.invalid_json(request_path))
      rescue StandardError => e
        warn "[#{request_path}] #{e.class}: #{e.message}"
        Cms::Http.json_error(req, Cms::Errors.internal(request_path))
      end
    end

    # One thread per connection. The body was already drained into the request
    # during parsing, so keep-alive is only unsafe when an oversized body was left
    # on the wire — then close after the response.
    def self.handle_connection(socket)
      socket.binmode
      peer = peer_ip(socket)
      loop do
        req = Cms::Http.parse_request(socket, peer)
        break if req.nil? || req == :bad
        alive = keep_alive?(req)
        resp = dispatch(req)
        resp.close_connection = true if req.body_too_large
        Cms::Http.write_response(socket, resp, alive)
        break if resp.close_connection || !alive
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      # Client went away mid-exchange; nothing to do.
    ensure
      begin
        socket.close
      rescue StandardError
        nil
      end
    end

    def self.main
      port = (ENV["PORT"] || "3016").to_i
      host = ENV["HOST"] || "0.0.0.0"
      Cms::Account.seed_admin
      server = TCPServer.new(host, port)
      warn "CMS API running at http://#{host}:#{port}"
      begin
        loop do
          client = server.accept
          Thread.new(client) { |sock| handle_connection(sock) }
        end
      rescue Interrupt
        nil
      ensure
        server.close
        warn "Server closed."
      end
    end
  end
end

Cms::Server.main if $PROGRAM_NAME == __FILE__
