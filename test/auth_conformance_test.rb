require_relative "test_helper"

# Five accounts cover the matrix, ownership and the workflow roles.
ACCOUNTS = [
  { "username" => "admin", "password" => "pw-admin", "role" => "admin" },
  { "username" => "editor", "password" => "pw-editor", "role" => "editor" },
  { "username" => "author", "password" => "pw-author", "role" => "author" },
  { "username" => "author2", "password" => "pw-author2", "role" => "author" },
  { "username" => "viewer", "password" => "pw-viewer", "role" => "viewer" },
].freeze

class AuthConformanceTest < Minitest::Test
  class << self
    attr_accessor :server, :token
  end

  WF = "BlogPosting"
  WB = "/blog-postings"
  SP = "creativeWorkStatus"
  INITIAL = "Draft"
  AUTHOR_TO = "Pending"
  EDITOR_TO = "Published"
  PUBLIC = "Published"

  def setup
    if self.class.server.nil?
      s = T.start_server(accounts: ACCOUNTS)
      self.class.server = s
      self.class.token = ACCOUNTS.each_with_object({}) { |a, h| h[a["username"]] = T.login(s, a["username"], a["password"]) }
      Minitest.after_run { s.stop }
    end
  end

  def server
    self.class.server
  end

  def token
    self.class.token
  end

  def req(bearer, method, path, body = nil)
    headers = bearer ? { "Authorization" => "Bearer #{bearer}" } : nil
    T.request_json(server, method, path, body, headers: headers, no_auth: true)
  end

  def create_as(bearer, entity, base, overrides = nil)
    # Dependencies (refs) are built as admin via the module token.
    T.set_auth_token(token["admin"])
    payload = T.build_payload(server, entity)
    payload.merge!(overrides) if overrides
    req(bearer, "POST", base, payload)
  end

  # --- Authentication ---------------------------------------------------

  def test_login_returns_token_account_expiry
    r = req(nil, "POST", "/auth/login", { "username" => "admin", "password" => "pw-admin" })
    assert_equal 200, r["status"]
    body = r["body"]
    assert_kind_of String, body["token"]
    assert_equal "admin", body["account"]["username"]
    assert_equal "admin", body["account"]["role"]
    assert body["account"]["id"]
    assert body["expiresAt"]
    refute_includes body["account"], "passwordHash"
  end

  def test_login_wrong_password_401
    r = req(nil, "POST", "/auth/login", { "username" => "admin", "password" => "wrong" })
    assert_equal 401, r["status"]
    assert_equal "UNAUTHORIZED", r["body"]["error"]
  end

  def test_login_unknown_user_same_401
    r = req(nil, "POST", "/auth/login", { "username" => "ghost", "password" => "whatever" })
    assert_equal 401, r["status"]
    assert_equal "UNAUTHORIZED", r["body"]["error"]
  end

  def test_login_missing_fields_400
    r = req(nil, "POST", "/auth/login", { "username" => "admin" })
    assert_equal 400, r["status"]
    assert_equal "VALIDATION_ERROR", r["body"]["error"]
  end

  def test_me_with_valid_token_returns_account
    r = req(token["author"], "GET", "/auth/me")
    assert_equal 200, r["status"]
    body = r["body"]
    assert_equal "author", body["account"]["username"]
    assert_equal "author", body["account"]["role"]
    refute_includes body["account"], "passwordHash"
  end

  def test_me_without_token_401
    r = req(nil, "GET", "/auth/me")
    assert_equal 401, r["status"]
  end

  def test_me_with_invalid_token_401
    r = req("not-a-real-token", "GET", "/auth/me")
    assert_equal 401, r["status"]
  end

  def test_logout_invalidates_session_immediately
    fresh = T.login(server, "viewer", "pw-viewer")
    out = req(fresh, "POST", "/auth/logout")
    assert_equal 204, out["status"]
    reuse = req(fresh, "GET", "/auth/me")
    assert_equal 401, reuse["status"]
    again = req(fresh, "POST", "/auth/logout")
    assert_equal 401, again["status"]
  end

  def test_logout_without_token_401
    r = req(nil, "POST", "/auth/logout")
    assert_equal 401, r["status"]
  end

  # --- Authorization (type-level) ---------------------------------------

  def test_write_without_session_is_401_not_403
    T.set_auth_token(token["admin"])
    payload = T.build_payload(server, WF)
    r = req(nil, "POST", WB, payload)
    assert_equal 401, r["status"]
  end

  def test_viewer_may_read_but_not_write
    item = create_as(token["admin"], WF, WB)["body"]
    assert_equal 200, req(token["viewer"], "GET", "#{WB}/#{item["id"]}")["status"]
    assert_equal 403, create_as(token["viewer"], WF, WB)["status"]
    assert_equal 403, req(token["viewer"], "PUT", "#{WB}/#{item["id"]}", {})["status"]
    assert_equal 403, req(token["viewer"], "DELETE", "#{WB}/#{item["id"]}")["status"]
  end

  def test_author_create_editor_admin_full_crud
    assert_equal 201, create_as(token["author"], WF, WB)["status"]
    assert_equal 201, create_as(token["editor"], WF, WB)["status"]
    assert_equal 201, create_as(token["admin"], WF, WB)["status"]
  end

  # --- Ownership --------------------------------------------------------

  def test_created_by_and_author_owns_only_own
    mine = create_as(token["author"], WF, WB)["body"]
    theirs = create_as(token["author2"], WF, WB)["body"]

    assert_equal 200, req(token["author"], "PUT", "#{WB}/#{mine["id"]}", {})["status"]
    assert_equal 403, req(token["author"], "PUT", "#{WB}/#{theirs["id"]}", {})["status"]
    assert_equal 403, req(token["author"], "DELETE", "#{WB}/#{theirs["id"]}")["status"]

    assert_equal 200, req(token["editor"], "PUT", "#{WB}/#{theirs["id"]}", {})["status"]
    assert_equal 204, req(token["admin"], "DELETE", "#{WB}/#{mine["id"]}")["status"]
  end

  # --- Field-level ------------------------------------------------------

  def test_created_by_never_in_response
    created = create_as(token["admin"], WF, WB)["body"]
    refute_includes created, "createdBy"
    got = req(token["admin"], "GET", "#{WB}/#{created["id"]}")["body"]
    refute_includes got, "createdBy"
    listed = req(token["admin"], "GET", "#{WB}?limit=100")["body"]
    listed["items"].each { |item| refute_includes item, "createdBy" }
  end

  def test_system_internal_fields_rejected_in_write
    T.set_auth_token(token["admin"])
    ["id", "dateCreated", "dateModified", "createdBy"].each do |field|
      payload = T.build_payload(server, WF)
      payload[field] = field == "id" ? "00000000-0000-0000-0000-000000000000" : "x"
      r = req(token["admin"], "POST", WB, payload)
      assert_equal 400, r["status"], "expected 400 for field #{field}, got #{r["status"]}"
      assert_equal "VALIDATION_ERROR", r["body"]["error"]
    end
  end

  def test_server_managed_fields_in_output
    created = create_as(token["admin"], WF, WB)["body"]
    assert created["id"]
    assert created["dateCreated"]
    assert created["dateModified"]
  end

  # --- Publication workflow ---------------------------------------------

  def test_fresh_record_has_initial_status
    created = create_as(token["author"], WF, WB)["body"]
    assert_equal INITIAL, created[SP]
  end

  def test_author_initial_transition_but_not_editor_only
    item = create_as(token["author"], WF, WB)["body"]
    a = req(token["author"], "PUT", "#{WB}/#{item["id"]}", { SP => AUTHOR_TO })
    assert_equal 200, a["status"]
    assert_equal AUTHOR_TO, a["body"][SP]
    b = req(token["author"], "PUT", "#{WB}/#{item["id"]}", { SP => EDITOR_TO })
    assert_equal 403, b["status"]
    c = req(token["editor"], "PUT", "#{WB}/#{item["id"]}", { SP => EDITOR_TO })
    assert_equal 200, c["status"]
  end

  def test_unmodelled_transition_forbidden
    item = create_as(token["editor"], WF, WB)["body"]
    r = req(token["editor"], "PUT", "#{WB}/#{item["id"]}", { SP => EDITOR_TO })
    assert_equal 403, r["status"]
  end

  # --- Anonymous visibility (public) ------------------------------------

  def test_anonymous_sees_only_public_non_public_detail_404
    item = create_as(token["admin"], WF, WB)["body"]

    hidden_list = req(nil, "GET", "#{WB}?limit=100")["body"]
    refute hidden_list["items"].any? { |i| i["id"] == item["id"] }
    assert_equal 404, req(nil, "GET", "#{WB}/#{item["id"]}")["status"]

    req(token["admin"], "PUT", "#{WB}/#{item["id"]}", { SP => AUTHOR_TO })
    publish = { SP => PUBLIC }
    publish["datePublished"] = "2020-01-01T00:00:00Z"
    pub = req(token["admin"], "PUT", "#{WB}/#{item["id"]}", publish)
    assert_equal 200, pub["status"]

    shown_list = req(nil, "GET", "#{WB}?limit=100")["body"]
    assert shown_list["items"].any? { |i| i["id"] == item["id"] }
    detail = req(nil, "GET", "#{WB}/#{item["id"]}")
    assert_equal 200, detail["status"]
    refute_includes detail["body"], "createdBy"
  end

  def test_plain_entity_anonymously_readable_no_workflow
    created = create_as(token["admin"], "Person", "/persons")["body"]
    anon = req(nil, "GET", "#{"/persons"}/#{created["id"]}")
    assert_equal 200, anon["status"]
    upd = req(token["editor"], "PUT", "#{"/persons"}/#{created["id"]}", {})
    assert_equal 200, upd["status"]
  end

  # --- Bootstrap --------------------------------------------------------

  def test_empty_store_plus_env_seeds_admin
    s = T.start_server(env: { "ADMIN_USER" => "root", "ADMIN_PASSWORD" => "root-pw" })
    begin
      t = T.login(s, "root", "root-pw")
      assert_kind_of String, t
    ensure
      s.stop
    end
  end

  def test_non_empty_store_makes_env_seed_noop
    s = T.start_server(accounts: ACCOUNTS, env: { "ADMIN_USER" => "ghost", "ADMIN_PASSWORD" => "ghost-pw" })
    begin
      direct = T.request_json(s, "POST", "/auth/login", { "username" => "ghost", "password" => "ghost-pw" }, no_auth: true)
      assert_equal 401, direct["status"]
    ensure
      s.stop
    end
  end

  def test_empty_store_without_env_grants_no_one
    s = T.start_server(accounts: [])
    begin
      # Dependencies (refs) are built as admin via the module token. Minitest
      # shuffles test order, so the token must be bound here, not inherited.
      T.set_auth_token(token["admin"])
      payload = T.build_payload(server, WF)
      r = T.request_json(s, "POST", WB, payload, no_auth: true)
      assert_equal 401, r["status"]
    ensure
      s.stop
    end
  end
end
