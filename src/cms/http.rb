require "json"
require "digest"
require "cgi"

module Cms
  module Http
    MAX_BODY_SIZE = 1024 * 1024
    MAX_JSON_DEPTH = 512

    CORS_HEADERS = {
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Content-Type, If-Match, If-None-Match",
      "Access-Control-Expose-Headers" => "ETag",
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Referrer-Policy" => "no-referrer",
      "Cache-Control" => "no-store",
    }.freeze

    STATUS_TEXT = {
      200 => "OK", 201 => "Created", 204 => "No Content", 304 => "Not Modified",
      400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
      404 => "Not Found", 405 => "Method Not Allowed", 412 => "Precondition Failed",
      413 => "Payload Too Large", 415 => "Unsupported Media Type",
      429 => "Too Many Requests", 500 => "Internal Server Error",
    }.freeze

    UUID_PATTERN = %r{\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z}i

    class BodyTooLargeError < StandardError; end
    class UnsupportedMediaTypeError < StandardError; end

    # A parsed request. Header names are lowercased; the body is read into memory
    # up front (bounded by MAX_BODY_SIZE) so the connection stays framed for
    # keep-alive. body_too_large flags a Content-Length over the cap; the body is
    # then deliberately left unread and the connection closed after the response.
    class Request
      attr_accessor :method, :path, :query, :headers, :client_ip, :raw_body, :body_too_large

      def initialize
        @headers = {}
        @raw_body = nil
        @body_too_large = false
      end

      def header(name)
        @headers[name.downcase]
      end
    end

    class Response
      attr_accessor :status, :headers, :body, :close_connection

      def initialize(status, headers, body = nil)
        @status = status
        @headers = headers
        @body = body
        @close_connection = false
      end
    end

    def self.valid_uuid?(value)
      value.is_a?(String) && !UUID_PATTERN.match(value).nil?
    end

    # Reads one request off the socket: request line, headers, then the body sized
    # by Content-Length. Returns nil at a clean connection close, :bad on a
    # malformed request line.
    def self.parse_request(socket, client_ip)
      request_line = socket.gets("\r\n")
      return nil if request_line.nil?
      request_line = request_line.chomp
      return nil if request_line.empty?
      parts = request_line.split(" ")
      return :bad if parts.length < 2

      req = Request.new
      req.method = parts[0]
      target = parts[1]
      mark = target.index("?")
      if mark.nil?
        req.path = target
        req.query = ""
      else
        req.path = target[0...mark]
        req.query = target[(mark + 1)..-1]
      end
      req.client_ip = client_ip

      loop do
        line = socket.gets("\r\n")
        break if line.nil?
        line = line.chomp
        break if line.empty?
        idx = line.index(":")
        next if idx.nil?
        name = line[0...idx].strip.downcase
        req.headers[name] = line[(idx + 1)..-1].strip
      end

      length = 0
      raw_len = req.headers["content-length"]
      if raw_len
        begin
          length = Integer(raw_len)
        rescue ArgumentError
          length = 0
        end
      end
      if length > MAX_BODY_SIZE
        req.body_too_large = true
      elsif length > 0
        req.raw_body = socket.read(length) || ""
      end
      req
    end

    def self.write_response(socket, response, keep_alive)
      reason = STATUS_TEXT[response.status] || "OK"
      lines = ["HTTP/1.1 #{response.status} #{reason}"]
      response.headers.each { |k, v| lines << "#{k}: #{v}" }
      if keep_alive && !response.close_connection
        lines << "Connection: keep-alive"
      else
        lines << "Connection: close"
      end
      data = lines.join("\r\n") + "\r\n\r\n"
      data += response.body if response.body
      socket.write(data)
    end

    def self.parse_query(query)
      result = {}
      return result if query.nil? || query.empty?
      query.split("&").each do |pair|
        next if pair.empty?
        key, _, value = pair.partition("=")
        k = CGI.unescape(key)
        result[k] ||= []
        result[k] << CGI.unescape(value)
      end
      result
    end

    def self.parse_body(req)
      raise BodyTooLargeError if req.body_too_large
      raw = req.raw_body
      return {} if raw.nil? || raw.empty?
      media = (req.headers["content-type"] || "").split(";")[0].to_s.strip.downcase
      raise UnsupportedMediaTypeError if media != "application/json"
      data = JSON.parse(raw, max_nesting: MAX_JSON_DEPTH)
      data.is_a?(Hash) ? data : {}
    end

    def self.generate_etag(body)
      '"' + Digest::SHA256.hexdigest(body)[0, 16] + '"'
    end

    def self.preflight
      Response.new(204, CORS_HEADERS.dup)
    end

    # Single-record responses pass the record's canonical ETag (the stored
    # record's version, the same value If-Match is checked against). Without one
    # the ETag falls back to a hash of the response body; lists and errors have
    # no single record version.
    def self.json_response(req, status, data, extra_headers = {}, etag = nil)
      return Response.new(204, CORS_HEADERS.dup) if status == 204
      body = JSON.generate(data)
      etag ||= generate_etag(body)
      inm = req.headers["if-none-match"]
      if !inm.nil? && (inm == etag || inm == "*")
        return Response.new(304, CORS_HEADERS.dup)
      end
      headers = CORS_HEADERS.dup
      headers["Content-Type"] = "application/json; charset=utf-8"
      headers["Content-Length"] = body.bytesize.to_s
      headers["ETag"] = etag
      extra_headers.each { |k, v| headers[k] = v }
      Response.new(status, headers, body)
    end

    def self.json_error(req, error, extra_headers = {})
      json_response(req, error["status"], error, extra_headers)
    end
  end
end
