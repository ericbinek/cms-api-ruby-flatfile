require_relative "account"
require_relative "sessions"

module Cms
  module Auth
    # HTTP methods that mutate state. No role grants anonymous writes, so any of
    # these without a session is a 401 before routing.
    WRITE_METHODS = ["POST", "PUT", "PATCH", "DELETE"].freeze

    ANONYMOUS = { "role" => "anonymous", "accountId" => nil, "username" => nil }.freeze

    BEARER = %r{\ABearer (.+)\z}

    # Thrown when a credential is presented but does not resolve. The server maps
    # it to 401. A missing credential is not an error — it is anonymous.
    class UnauthorizedError < StandardError; end

    def self.bearer_token(req)
      header = req.header("authorization")
      return nil if header.nil? || header.empty?
      match = BEARER.match(header.strip)
      match ? match[1] : ""
    end

    # Resolves the request principal. No Authorization header -> anonymous. A
    # Bearer token that does not resolve to a live session (or a malformed header)
    # raises UnauthorizedError. Fails closed: a presented credential must be valid.
    def self.resolve_principal(req)
      token = bearer_token(req)
      return ANONYMOUS if token.nil?
      raise UnauthorizedError if token == ""
      session = Cms::Sessions.resolve_session(token)
      raise UnauthorizedError if session.nil?
      account = Cms::Account.find_by_id(session["accountId"])
      raise UnauthorizedError if account.nil?
      { "role" => account["role"], "accountId" => account["id"], "username" => account["username"] }
    end

    # A write method by an unauthenticated principal needs a session: 401. Guards
    # for an authenticated-but-unauthorized principal are the router's 403.
    def self.requires_session?(method, principal)
      WRITE_METHODS.include?(method) && principal["role"] == "anonymous"
    end
  end
end
