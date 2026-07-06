module Cms
  module Errors
    # A unique-key collision raised from a model. Carries the response details so
    # the server can report it in the existing validation envelope (400), not a
    # new error type.
    class DuplicateError < StandardError
      attr_reader :details

      def initialize(details)
        super("Unique key collision.")
        @details = details
      end
    end

    def self.build(status, error, message, details = [], path = "")
      { "status" => status, "error" => error, "message" => message, "details" => details, "path" => path }
    end

    def self.validation(details, path)
      build(400, "VALIDATION_ERROR", "Invalid request data.", details, path)
    end

    def self.invalid_json(path)
      build(400, "INVALID_JSON", "Request body is not valid JSON.", [], path)
    end

    def self.invalid_id(path)
      build(400, "INVALID_ID", "ID must be a valid UUID.", [], path)
    end

    def self.unauthorized(path)
      build(401, "UNAUTHORIZED", "Authentication is required, or the session is invalid or expired.", [], path)
    end

    def self.forbidden(message, path)
      build(403, "FORBIDDEN", message || "You do not have permission to perform this operation.", [], path)
    end

    def self.not_found(resource, path)
      build(404, "NOT_FOUND", "#{resource} not found.", [], path)
    end

    def self.route_not_found(path)
      build(404, "ROUTE_NOT_FOUND", "No route matches this request.", [], path)
    end

    def self.method_not_allowed(allowed, path)
      build(405, "METHOD_NOT_ALLOWED", "Method not allowed. Allowed: #{allowed.join(", ")}.", [], path)
    end

    def self.too_many_requests(path)
      build(429, "TOO_MANY_REQUESTS", "Rate limit exceeded. Try again later.", [], path)
    end

    def self.precondition_failed(path)
      build(412, "PRECONDITION_FAILED", "ETag does not match current resource state.", [], path)
    end

    def self.payload_too_large(path)
      build(413, "PAYLOAD_TOO_LARGE", "Request body too large.", [], path)
    end

    def self.unsupported_media_type(path)
      build(415, "UNSUPPORTED_MEDIA_TYPE", "Request body must be application/json.", [], path)
    end

    def self.internal(path)
      build(500, "INTERNAL_ERROR", "Internal server error.", [], path)
    end
  end
end
