require "json"
require "time"

# Compiled access policy for this target, derived from the project-wide access/
# authority (roles.json, field-access.json, workflow.json). Pure data plus pure
# helpers — no IO, no request handling. The router and server enforce it.

module Cms
  module Access
    POLICY = JSON.parse(<<~'ACCESS_POLICY_JSON')
      {
        "operations": [
          "read",
          "create",
          "update",
          "delete"
        ],
        "roles": {
          "admin": {
            "description": "Full access to every entity plus account management.",
            "matrix": {
              "*": [
                "read",
                "create",
                "update",
                "delete"
              ]
            },
            "accountManagement": true
          },
          "editor": {
            "description": "Full CRUD on every entity. Drives the publication workflow.",
            "matrix": {
              "*": [
                "read",
                "create",
                "update",
                "delete"
              ]
            }
          },
          "author": {
            "description": "Reads and creates every entity, but updates and deletes only own records.",
            "matrix": {
              "*": [
                "read",
                "create",
                "update",
                "delete"
              ]
            },
            "ownership": {
              "scope": "own",
              "operations": [
                "update",
                "delete"
              ],
              "field": "createdBy"
            }
          },
          "viewer": {
            "description": "Authenticated read only across every entity, including non public status.",
            "matrix": {
              "*": [
                "read"
              ]
            }
          },
          "anonymous": {
            "description": "Unauthenticated read, no session. Restricted to publicly visible records via the read visibility rule.",
            "matrix": {
              "*": [
                "read"
              ]
            },
            "read": {
              "visibility": "public"
            }
          }
        },
        "visibility": {
          "description": "Read visibility scopes a role read rule can reference. \"all\" returns every record, so reads stay backward compatible with the current auth free API. \"public\" restricts status bearing entities to their public states defined in access/workflow.json, and where a datePublished property exists it must be reached; entities without a status enum stay fully readable either way. Which scope the anonymous role ships with at rollout is the open decision for the API auth block, see docs/auth/implementation-plan.md.",
          "scopes": [
            "all",
            "public"
          ]
        },
        "fieldGroups": {
          "system": [
            "id",
            "dateCreated",
            "dateModified"
          ],
          "internal": [
            "createdBy"
          ]
        },
        "fieldRules": {
          "*": {
            "read": {
              "deny": [
                "@internal"
              ]
            },
            "write": {
              "deny": [
                "@system",
                "@internal"
              ]
            }
          }
        },
        "workflow": {
          "BlogPosting": {
            "statusProperty": "creativeWorkStatus",
            "initial": "Draft",
            "public": [
              "Published"
            ],
            "transitions": [
              {
                "from": "Draft",
                "to": "Pending",
                "roles": [
                  "author",
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Pending",
                "to": "Draft",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Pending",
                "to": "Published",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Published",
                "to": "Archived",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Archived",
                "to": "Published",
                "roles": [
                  "editor",
                  "admin"
                ]
              }
            ],
            "hasPublishDate": true
          },
          "WebPage": {
            "statusProperty": "creativeWorkStatus",
            "initial": "Draft",
            "public": [
              "Published"
            ],
            "transitions": [
              {
                "from": "Draft",
                "to": "Pending",
                "roles": [
                  "author",
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Pending",
                "to": "Draft",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Pending",
                "to": "Published",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Published",
                "to": "Archived",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Archived",
                "to": "Published",
                "roles": [
                  "editor",
                  "admin"
                ]
              }
            ],
            "hasPublishDate": true
          },
          "Comment": {
            "statusProperty": "creativeWorkStatus",
            "initial": "Pending",
            "public": [
              "Approved"
            ],
            "transitions": [
              {
                "from": "Pending",
                "to": "Approved",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Pending",
                "to": "Spam",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Approved",
                "to": "Spam",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Approved",
                "to": "Trash",
                "roles": [
                  "editor",
                  "admin"
                ]
              },
              {
                "from": "Spam",
                "to": "Trash",
                "roles": [
                  "editor",
                  "admin"
                ]
              }
            ],
            "hasPublishDate": false
          }
        }
      }
    ACCESS_POLICY_JSON

    ROLES = POLICY["roles"]
    WORKFLOW = POLICY["workflow"]
    SYSTEM_FIELDS = POLICY["fieldGroups"]["system"]
    INTERNAL_FIELDS = POLICY["fieldGroups"]["internal"]
    FIELD_RULES = POLICY["fieldRules"]

    # Resolves a role's field rule for a mode (read/write) into a concrete deny
    # list, expanding @system and @internal. A per-role rule wins over the "*"
    # default; an absent rule denies nothing.
    def self.deny_set(role, mode)
      by_role = (FIELD_RULES[role] || {})[mode]
      by_default = (FIELD_RULES["*"] || {})[mode]
      rule = by_role || by_default || {}
      deny = []
      (rule["deny"] || []).each do |entry|
        if entry == "@system"
          deny.concat(SYSTEM_FIELDS)
        elsif entry == "@internal"
          deny.concat(INTERNAL_FIELDS)
        else
          deny << entry
        end
      end
      deny
    end

    # The fields no client may ever write (system + internal), i.e. the default
    # write deny resolved. Exposed for request builders and tests.
    READONLY_FIELDS = deny_set("*", "write").freeze

    # Type-level: may role perform op on entity? A per-entity matrix entry overrides
    # the "*" default for that entity only.
    def self.can?(role, entity, op)
      r = ROLES[role]
      return false if r.nil? || !r.key?("matrix")
      matrix = r["matrix"]
      ops = matrix.key?(entity) ? matrix[entity] : matrix["*"]
      ops.is_a?(Array) && ops.include?(op)
    end

    # Ownership: the owner field name if role is restricted to its own records for
    # op (e.g. author update/delete -> "createdBy"), else nil.
    def self.ownership_field(role, op)
      own = (ROLES[role] || {})["ownership"]
      return nil if own.nil? || !own["operations"].include?(op)
      own["field"]
    end

    def self.governed?(entity)
      WORKFLOW.key?(entity)
    end

    def self.status_property(entity)
      governed?(entity) ? WORKFLOW[entity]["statusProperty"] : nil
    end

    def self.initial_status(entity)
      governed?(entity) ? WORKFLOW[entity]["initial"] : nil
    end

    # May role move entity from frm to to? Non-governed entities and no-op
    # transitions are always allowed; everything else must be modelled.
    def self.transition_allowed?(entity, frm, to, role)
      return true unless governed?(entity)
      return true if frm == to
      WORKFLOW[entity]["transitions"].any? { |t| t["from"] == frm && t["to"] == to && t["roles"].include?(role) }
    end

    # Field-level write: the names in body a role may not set (system and internal
    # fields). Any hit is a 400, not a silent drop.
    def self.readonly_violations(role, body)
      return [] unless body.is_a?(Hash)
      deny = deny_set(role, "write")
      body.keys.select { |k| deny.include?(k) }
    end

    # Field-level read: strip denied (internal) fields from a value before it leaves
    # the server, recursing into lists and embedded objects.
    def self.strip_fields(role, value)
      deny = deny_set(role, "read")
      walk = nil
      walk = lambda do |v|
        if v.is_a?(Array)
          v.map { |e| walk.call(e) }
        elsif v.is_a?(Hash)
          out = {}
          v.each { |k, val| out[k] = walk.call(val) unless deny.include?(k) }
          out
        else
          v
        end
      end
      walk.call(value)
    end

    # On create the server stamps ownership (createdBy) and forces the workflow
    # entry state, overriding any client-supplied status.
    def self.apply_create_defaults(entity, data, account_id)
      out = data.merge("createdBy" => account_id)
      initial = initial_status(entity)
      out[status_property(entity)] = initial unless initial.nil?
      out
    end

    def self.read_visibility(role)
      r = ROLES[role] || {}
      (r["read"] || {}).fetch("visibility", "all")
    end

    # Lenient ISO 8601 parse for the datePublished gate; a trailing Z is accepted.
    def self.parse_iso(value)
      return nil unless value.is_a?(String)
      Time.iso8601(value).to_f
    rescue ArgumentError
      nil
    end

    # Anonymous read visibility: "public" gates status-bearing entities to their
    # public states and a reached publish date; "all" returns every record.
    def self.visible?(role, entity, item)
      return true if read_visibility(role) != "public"
      return true unless governed?(entity)
      wf = WORKFLOW[entity]
      return false unless wf["public"].include?(item[wf["statusProperty"]])
      if wf["hasPublishDate"]
        at = parse_iso(item["datePublished"])
        return false if at.nil? || at > Time.now.to_f
      end
      true
    end
  end
end
