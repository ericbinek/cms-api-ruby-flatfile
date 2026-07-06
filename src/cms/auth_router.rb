require_relative "http"
require_relative "errors"
require_relative "sessions"
require_relative "account"

module Cms
  module AuthRouter
    BASE = "/auth"
    BEARER = %r{\ABearer (.+)\z}

    def self.bearer_token(req)
      header = req.header("authorization")
      return nil if header.nil? || header.empty?
      match = BEARER.match(header.strip)
      match ? match[1] : nil
    end

    # The principal is attached by the server middleware before routing. login is
    # reachable anonymously; logout and me require a live session. Returns a
    # Response when the path is an /auth route, otherwise nil.
    def self.handle(req, method, path, request_path, principal)
      if path == BASE + "/login"
        return Cms::Http.json_error(req, Cms::Errors.method_not_allowed(["POST"], request_path)) if method != "POST"
        body = Cms::Http.parse_body(req)
        unless body["username"].is_a?(String) && body["password"].is_a?(String)
          return Cms::Http.json_error(req, Cms::Errors.validation(['Fields "username" and "password" are required.'], request_path))
        end
        # Same 401 for unknown user and wrong password — no user enumeration.
        account = Cms::Account.authenticate(body["username"], body["password"])
        return Cms::Http.json_error(req, Cms::Errors.unauthorized(request_path)) if account.nil?
        issued = Cms::Sessions.create_session(account["id"])
        return Cms::Http.json_response(req, 200, {
          "token" => issued["token"],
          "account" => { "id" => account["id"], "username" => account["username"], "role" => account["role"] },
          "expiresAt" => issued["expiresAt"],
        })
      end

      if path == BASE + "/logout"
        return Cms::Http.json_error(req, Cms::Errors.method_not_allowed(["POST"], request_path)) if method != "POST"
        # Idempotent by token: a missing or already-deleted token is 401.
        token = bearer_token(req)
        removed = token ? Cms::Sessions.delete_session(token) : false
        return Cms::Http.json_error(req, Cms::Errors.unauthorized(request_path)) unless removed
        return Cms::Http.json_response(req, 204, nil)
      end

      if path == BASE + "/me"
        return Cms::Http.json_error(req, Cms::Errors.method_not_allowed(["GET"], request_path)) if method != "GET"
        return Cms::Http.json_error(req, Cms::Errors.unauthorized(request_path)) if principal["role"] == "anonymous"
        return Cms::Http.json_response(req, 200, {
          "account" => { "id" => principal["accountId"], "username" => principal["username"], "role" => principal["role"] },
        })
      end

      nil
    end
  end
end
