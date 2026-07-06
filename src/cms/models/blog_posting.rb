require_relative "../errors"
require_relative "../storage"
require_relative "../validation"

module Cms
  module Models
    module BlogPosting
      TYPE_NAME = "BlogPosting"
      COLLECTION_FILE = "blog-postings.json"

      FIELDS = {
        "headline" => { "kind" => "scalar", "type" => "Text", "cardinality" => "one", "maxLength" => 256 },
        "alternativeHeadline" => { "kind" => "scalar", "type" => "Text", "cardinality" => "one", "maxLength" => 256 },
        "description" => { "kind" => "scalar", "type" => "Text", "cardinality" => "one", "maxLength" => 5000, "multiline" => true },
        "articleBody" => { "kind" => "scalar", "type" => "Text", "cardinality" => "one", "maxLength" => 65536, "multiline" => true },
        "author" => { "kind" => "ref", "targets" => ["Person"], "cardinality" => "one" },
        "publisher" => { "kind" => "ref", "targets" => ["Organization"], "cardinality" => "one" },
        "image" => { "kind" => "ref", "targets" => ["ImageObject"], "cardinality" => "many" },
        "video" => { "kind" => "ref", "targets" => ["VideoObject"], "cardinality" => "many" },
        "audio" => { "kind" => "ref", "targets" => ["AudioObject"], "cardinality" => "many" },
        "keywords" => { "kind" => "ref", "targets" => ["DefinedTerm"], "cardinality" => "many" },
        "about" => { "kind" => "ref", "targets" => ["CategoryCode"], "cardinality" => "many" },
        "datePublished" => { "kind" => "scalar", "type" => "DateTime", "cardinality" => "one" },
        "dateModified" => { "kind" => "scalar", "type" => "DateTime", "cardinality" => "one" },
        "dateCreated" => { "kind" => "scalar", "type" => "DateTime", "cardinality" => "one" },
        "url" => { "kind" => "scalar", "type" => "URL", "cardinality" => "one", "maxLength" => 2048 },
        "inLanguage" => { "kind" => "embed", "type" => "Language", "cardinality" => "one" },
        "isAccessibleForFree" => { "kind" => "scalar", "type" => "Boolean", "cardinality" => "one" },
        "wordCount" => { "kind" => "scalar", "type" => "Integer", "cardinality" => "one" },
        "creativeWorkStatus" => { "kind" => "enum", "values" => ["Draft", "Pending", "Published", "Archived"], "cardinality" => "one" },
      }.freeze

      REQUIRED_FIELDS = ["headline", "articleBody", "author", "url"].freeze
      SEARCHABLE_FIELDS = ["headline", "alternativeHeadline", "description", "articleBody"].freeze
      SORTABLE_FIELDS = ["dateCreated", "dateModified", "headline", "alternativeHeadline", "description", "articleBody", "datePublished", "url", "isAccessibleForFree", "wordCount", "creativeWorkStatus"].freeze

      # Properties whose combined value must be unique across the collection. Empty
      # when the entity allows duplicates.
      UNIQUE_KEY = ["url"].freeze

      SYSTEM_FIELDS = ["id", "dateCreated", "dateModified", "@context", "@type"].freeze

      REF_COLLECTIONS = { "Person" => "persons.json", "Organization" => "organizations.json", "ImageObject" => "image-objects.json", "VideoObject" => "video-objects.json", "AudioObject" => "audio-objects.json", "DefinedTerm" => "defined-terms.json", "CategoryCode" => "category-codes.json" }.freeze

      def self.empty_value?(value)
        return true if value.nil?
        return true if value == ""
        return true if value.is_a?(Array) && value.empty?
        false
      end

      def self.check_one(spec, value, path)
        case spec["kind"]
        when "scalar"
          return [%(Field "#{path}" must be a #{spec["type"]}.)] unless Cms::Validation.check_scalar(spec["type"], value)
          max_length = spec["maxLength"]
          if !max_length.nil? && value.is_a?(String) && value.length > max_length
            return [%(Field "#{path}" must be at most #{max_length} characters.)]
          end
        when "enum"
          return [%(Field "#{path}" must be one of: #{spec["values"].join(", ")}.)] unless spec["values"].include?(value)
        when "ref"
          return [%(Field "#{path}" must be a UUID.)] unless Cms::Validation.valid_uuid?(value)
        when "embed"
          return [%(Field "#{path}" must be an inline #{spec["type"]} embed with @type set.)] unless Cms::Validation.embed?(value, spec["type"])
        end
        []
      end

      def self.check_field(spec, value, name)
        if spec["cardinality"] == "many"
          return [%(Field "#{name}" must be an array.)] unless value.is_a?(Array)
          errors = []
          value.each_with_index { |v, i| errors.concat(check_one(spec, v, "#{name}[#{i}]")) }
          return errors
        end
        check_one(spec, value, name)
      end

      def self.validate(data, partial = false)
        return ["Request body must be a JSON object."] unless data.is_a?(Hash)
        errors = []
        data.keys.each do |key|
          if !key.is_a?(String) || Cms::Validation.dangerous_key?(key)
            errors << %(Unknown field "#{key}".)
            next
          end
          errors << %(Unknown field "#{key}".) unless FIELDS.key?(key) || SYSTEM_FIELDS.include?(key)
        end
        if !partial
          REQUIRED_FIELDS.each do |field|
            errors << %(Field "#{field}" is required.) if empty_value?(data[field])
          end
        else
          # A partial update may omit a required field, but must not blank one that
          # is present — that would leave the resource violating its own contract.
          REQUIRED_FIELDS.each do |field|
            errors << %(Field "#{field}" must not be empty.) if data.key?(field) && empty_value?(data[field])
          end
        end
        FIELDS.each do |name, spec|
          next unless data.key?(name)
          errors.concat(check_field(spec, data[name], name))
        end
        errors
      end

      def self.now_iso
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      end

      # Field-aware input cleaning, run before validation and storage: each known
      # scalar string is normalized, stripped of control characters and trimmed,
      # with long-form (multiline) fields keeping their internal line breaks.
      # Mutates in place; dangerous keys are deliberately left untouched so
      # validate() can reject them rather than silently dropping them here.
      def self.sanitize(data)
        return data unless data.is_a?(Hash)
        data.keys.each do |key|
          next if Cms::Validation.dangerous_key?(key)
          value = data[key]
          spec = FIELDS[key]
          if !spec.nil? && spec["kind"] == "scalar" && value.is_a?(String)
            data[key] = Cms::Validation.sanitize_string(value, spec.fetch("multiline", false))
          else
            data[key] = Cms::Validation.deep_sanitize(value)
          end
        end
        data
      end

      def self.normalize_refs(data)
        FIELDS.each do |name, spec|
          next unless spec["kind"] == "ref" && data.key?(name)
          if spec["cardinality"] == "many" && data[name].is_a?(Array)
            data[name] = data[name].map { |v| Cms::Validation.normalize_uuid(v) }
          elsif data[name].is_a?(String)
            data[name] = Cms::Validation.normalize_uuid(data[name])
          end
        end
        data
      end

      def self.number?(value)
        value.is_a?(Numeric)
      end

      # Type-aware ordering: numbers numerically, booleans as booleans, everything
      # else lexicographically by string form. Missing values (nil) always sort
      # last, regardless of order.
      def self.compare_for_sort(va, vb, direction)
        a_missing = va.nil?
        b_missing = vb.nil?
        if a_missing || b_missing
          return 0 if a_missing && b_missing
          return a_missing ? 1 : -1
        end
        if (va == true || va == false) && (vb == true || vb == false)
          cmp = va == vb ? 0 : (va == true ? 1 : -1)
        elsif number?(va) && number?(vb)
          cmp = va <=> vb
        else
          cmp = va.to_s <=> vb.to_s
        end
        cmp * direction
      end

      def self.find_all(filter: nil, sort: "dateCreated", order: "desc", limit: 20, offset: 0)
        items = Cms::Storage.read_collection(COLLECTION_FILE)
        if filter && !filter.empty?
          filter.each do |field, value|
            next unless SEARCHABLE_FIELDS.include?(field)
            needle = value.to_s.downcase
            items = items.select { |i| i[field].is_a?(String) && i[field].downcase.include?(needle) }
          end
        end
        sort_field = SORTABLE_FIELDS.include?(sort) ? sort : "dateCreated"
        direction = order == "asc" ? 1 : -1
        items = items.sort { |a, b| compare_for_sort(a[sort_field], b[sort_field], direction) }
        { "items" => items[offset, limit] || [], "total" => items.length }
      end

      def self.find_by_id(id)
        return nil unless Cms::Validation.valid_uuid?(id)
        normalized = Cms::Validation.normalize_uuid(id)
        Cms::Storage.read_collection(COLLECTION_FILE).find { |item| item["id"] == normalized }
      end

      # Embeds referenced entities one level deep for single-resource GET (JSON-LD
      # style): each ref UUID is replaced by the referenced object. List responses
      # stay flat. A ref that no longer resolves is left as the stored UUID string.
      def self.embed_refs(item)
        cache = {}
        load_collection = lambda { |file| cache[file] ||= Cms::Storage.read_collection(file) }
        resolve_ref = lambda do |value, targets|
          next value unless value.is_a?(String)
          targets.each do |target|
            file = REF_COLLECTIONS[target]
            next unless file
            entry = load_collection.call(file).find { |e| e["id"] == value }
            return entry unless entry.nil?
          end
          value
        end
        out = item.dup
        FIELDS.each do |name, spec|
          next unless spec["kind"] == "ref" && !out[name].nil?
          if spec["cardinality"] == "many"
            next unless out[name].is_a?(Array)
            out[name] = out[name].map { |v| resolve_ref.call(v, spec["targets"]) }
          else
            out[name] = resolve_ref.call(out[name], spec["targets"])
          end
        end
        out
      end

      # A candidate collides when some other record shares every unique-key value.
      # Comparison runs on already-sanitized, ref-normalized data.
      def self.violates_unique_key?(items, candidate, exclude_id)
        return false if UNIQUE_KEY.empty?
        items.any? do |item|
          next false if item["id"] == exclude_id
          UNIQUE_KEY.all? { |field| item[field] == candidate[field] }
        end
      end

      def self.duplicate_error
        fields = UNIQUE_KEY.join(" and ")
        Cms::Errors::DuplicateError.new([%(A #{TYPE_NAME} with this #{fields} already exists.)])
      end

      def self.create(raw_data)
        Cms::Storage.with_lock do
          data = normalize_refs(raw_data)
          items = Cms::Storage.read_collection(COLLECTION_FILE)
          raise duplicate_error if violates_unique_key?(items, data, nil)
          now = now_iso
          # Client data first, then system-controlled fields override it: a client
          # cannot spoof @context/@type/id/timestamps by sending them in the body.
          item = data.merge(
            "@context" => "https://schema.org",
            "@type" => TYPE_NAME,
            "id" => Cms::Validation.generate_uuid,
            "dateCreated" => now,
            "dateModified" => now,
          )
          items << item
          Cms::Storage.write_collection(COLLECTION_FILE, items)
          item
        end
      end

      def self.update(id, raw_data)
        Cms::Storage.with_lock do
          items = Cms::Storage.read_collection(COLLECTION_FILE)
          normalized = Cms::Validation.normalize_uuid(id)
          index = items.index { |item| item["id"] == normalized }
          return nil if index.nil?
          current = items[index]
          data = normalize_refs(raw_data)
          updated = current.merge(data).merge(
            "@context" => current.fetch("@context", "https://schema.org"),
            "@type" => current.fetch("@type", TYPE_NAME),
            "id" => current["id"],
            "dateCreated" => current["dateCreated"],
            "dateModified" => now_iso,
          )
          raise duplicate_error if violates_unique_key?(items, updated, current["id"])
          items[index] = updated
          Cms::Storage.write_collection(COLLECTION_FILE, items)
          updated
        end
      end

      def self.remove(id)
        Cms::Storage.with_lock do
          items = Cms::Storage.read_collection(COLLECTION_FILE)
          normalized = Cms::Validation.normalize_uuid(id)
          filtered = items.reject { |i| i["id"] == normalized }
          return false if filtered.length == items.length
          Cms::Storage.write_collection(COLLECTION_FILE, filtered)
          true
        end
      end

      def self.etag_of(item)
        Cms::Validation.etag_for(item)
      end
    end
  end
end
