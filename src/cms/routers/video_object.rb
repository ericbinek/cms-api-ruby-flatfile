require_relative "../http"
require_relative "../errors"
require_relative "../access"
require_relative "../models/video_object"

module Cms
  module Routers
    module VideoObject
      MODEL = Cms::Models::VideoObject
      ENTITY = "VideoObject"
      BASE = "/video-objects"
      MAX_LIMIT = 100
      DEFAULT_LIMIT = 20
      SYSTEM_FILTER_KEYS = ["limit", "offset", "sort", "order"].freeze
      ALL = (2**63) - 1 # request the full set from the model before visibility filtering

      def self.integer_or_nil(value)
        Integer(value, 10)
      rescue ArgumentError, TypeError
        nil
      end

      def self.parse_list_options(query)
        qs = Cms::Http.parse_query(query)
        errors = []

        limit = DEFAULT_LIMIT
        if qs.key?("limit")
          n = integer_or_nil(qs["limit"][0])
          if n.nil? || n < 1 || n > MAX_LIMIT
            errors << %(Query "limit" must be an integer between 1 and #{MAX_LIMIT}.)
          else
            limit = n
          end
        end

        offset = 0
        if qs.key?("offset")
          n = integer_or_nil(qs["offset"][0])
          if n.nil? || n < 0
            errors << %(Query "offset" must be a non-negative integer.)
          else
            offset = n
          end
        end

        sort = "dateCreated"
        if qs.key?("sort")
          v = qs["sort"][0]
          if MODEL::SORTABLE_FIELDS.include?(v)
            sort = v
          else
            errors << %(Query "sort" must be one of: #{MODEL::SORTABLE_FIELDS.sort.join(", ")}.)
          end
        end

        order = "desc"
        if qs.key?("order")
          v = qs["order"][0]
          if v == "asc" || v == "desc"
            order = v
          else
            errors << %(Query "order" must be "asc" or "desc".)
          end
        end

        filter = {}
        qs.each do |key, values|
          next if SYSTEM_FILTER_KEYS.include?(key)
          unless MODEL::SEARCHABLE_FIELDS.include?(key)
            errors << %(Unknown filter field "#{key}".)
            next
          end
          filter[key] = values[0]
        end

        { "limit" => limit, "offset" => offset, "sort" => sort, "order" => order, "filter" => filter, "errors" => errors }
      end

      # Returns a Response when this router owns the path, otherwise nil so the
      # server tries the next router (and finally a 404).
      def self.handle(req, method, path, request_path, principal)
        return handle_collection(req, method, request_path, principal) if path == BASE
        if path.start_with?(BASE + "/")
          rest = path[(BASE.length + 1)..-1]
          return nil if rest.include?("/")
          return handle_item(req, method, rest, request_path, principal)
        end
        nil
      end

      def self.handle_collection(req, method, request_path, principal)
        role = principal["role"]
        if method == "GET"
          unless Cms::Access.can?(role, ENTITY, "read")
            return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Role "#{role}" may not read #{ENTITY}.), request_path))
          end
          opts = parse_list_options(req.query)
          return Cms::Http.json_error(req, Cms::Errors.validation(opts["errors"], request_path)) unless opts["errors"].empty?
          # Apply read visibility on the full filtered set, then paginate, so total
          # counts only the records this principal may see. Internal fields stripped.
          result = MODEL.find_all(filter: opts["filter"], sort: opts["sort"], order: opts["order"], limit: ALL, offset: 0)
          visible = result["items"].select { |item| Cms::Access.visible?(role, ENTITY, item) }
          page = visible[opts["offset"], opts["limit"]] || []
          items = page.map { |item| Cms::Access.strip_fields(role, item) }
          return Cms::Http.json_response(req, 200, { "items" => items, "total" => visible.length })
        end
        if method == "POST"
          unless Cms::Access.can?(role, ENTITY, "create")
            return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Role "#{role}" may not create #{ENTITY}.), request_path))
          end
          body = MODEL.sanitize(Cms::Http.parse_body(req))
          readonly = Cms::Access.readonly_violations(role, body)
          unless readonly.empty?
            return Cms::Http.json_error(req, Cms::Errors.validation([%(Fields are not writable: #{readonly.join(", ")}.)], request_path))
          end
          errs = MODEL.validate(body)
          return Cms::Http.json_error(req, Cms::Errors.validation(errs, request_path)) unless errs.empty?
          created = MODEL.create(Cms::Access.apply_create_defaults(ENTITY, body, principal["accountId"]))
          return Cms::Http.json_response(req, 201, Cms::Access.strip_fields(role, created), { "Location" => "#{BASE}/#{created["id"]}" }, MODEL.etag_of(created))
        end
        Cms::Http.json_error(req, Cms::Errors.method_not_allowed(["GET", "POST"], request_path))
      end

      def self.handle_item(req, method, item_id, request_path, principal)
        role = principal["role"]
        return Cms::Http.json_error(req, Cms::Errors.invalid_id(request_path)) unless Cms::Http.valid_uuid?(item_id)

        if method == "GET"
          unless Cms::Access.can?(role, ENTITY, "read")
            return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Role "#{role}" may not read #{ENTITY}.), request_path))
          end
          item = MODEL.find_by_id(item_id)
          # A record the principal may not see is indistinguishable from a missing
          # one (404, never 403) so its existence is not disclosed.
          if item.nil? || !Cms::Access.visible?(role, ENTITY, item)
            return Cms::Http.json_error(req, Cms::Errors.not_found(MODEL::TYPE_NAME, request_path))
          end
          # The ETag names the stored record's version, not the role- and
          # embedding-shaped body -- it must satisfy a later If-Match.
          return Cms::Http.json_response(req, 200, Cms::Access.strip_fields(role, MODEL.embed_refs(item)), {}, MODEL.etag_of(item))
        end

        if method == "PUT"
          unless Cms::Access.can?(role, ENTITY, "update")
            return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Role "#{role}" may not update #{ENTITY}.), request_path))
          end
          body = MODEL.sanitize(Cms::Http.parse_body(req))
          readonly = Cms::Access.readonly_violations(role, body)
          unless readonly.empty?
            return Cms::Http.json_error(req, Cms::Errors.validation([%(Fields are not writable: #{readonly.join(", ")}.)], request_path))
          end
          errs = MODEL.validate(body, true)
          return Cms::Http.json_error(req, Cms::Errors.validation(errs, request_path)) unless errs.empty?
          current = MODEL.find_by_id(item_id)
          return Cms::Http.json_error(req, Cms::Errors.not_found(MODEL::TYPE_NAME, request_path)) if current.nil?
          owner_field = Cms::Access.ownership_field(role, "update")
          if owner_field && current[owner_field] != principal["accountId"]
            return Cms::Http.json_error(req, Cms::Errors.forbidden("You may only modify your own records.", request_path))
          end
          if_match = req.header("if-match")
          if if_match && if_match != "*" && if_match != MODEL.etag_of(current)
            return Cms::Http.json_error(req, Cms::Errors.precondition_failed(request_path))
          end
          status = Cms::Access.status_property(ENTITY)
          if status && body.key?(status) && body[status] != current[status]
            unless Cms::Access.transition_allowed?(ENTITY, current[status], body[status], role)
              return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Status transition #{current[status]} -> #{body[status]} is not allowed for role "#{role}".), request_path))
            end
          end
          # update() returns nil when the record vanished between the lookup
          # above and the write (concurrent delete) -- a 404, same as the lookup.
          updated = MODEL.update(item_id, body)
          return Cms::Http.json_error(req, Cms::Errors.not_found(MODEL::TYPE_NAME, request_path)) if updated.nil?
          return Cms::Http.json_response(req, 200, Cms::Access.strip_fields(role, updated), {}, MODEL.etag_of(updated))
        end

        if method == "DELETE"
          unless Cms::Access.can?(role, ENTITY, "delete")
            return Cms::Http.json_error(req, Cms::Errors.forbidden(%(Role "#{role}" may not delete #{ENTITY}.), request_path))
          end
          current = MODEL.find_by_id(item_id)
          return Cms::Http.json_error(req, Cms::Errors.not_found(MODEL::TYPE_NAME, request_path)) if current.nil?
          owner_field = Cms::Access.ownership_field(role, "delete")
          if owner_field && current[owner_field] != principal["accountId"]
            return Cms::Http.json_error(req, Cms::Errors.forbidden("You may only delete your own records.", request_path))
          end
          if_match = req.header("if-match")
          if if_match && if_match != "*" && if_match != MODEL.etag_of(current)
            return Cms::Http.json_error(req, Cms::Errors.precondition_failed(request_path))
          end
          MODEL.remove(item_id)
          return Cms::Http.json_response(req, 204, nil)
        end

        Cms::Http.json_error(req, Cms::Errors.method_not_allowed(["GET", "PUT", "DELETE"], request_path))
      end
    end
  end
end
