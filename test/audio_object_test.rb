require_relative "test_helper"

class AudioObjectApiTest < Minitest::Test
  ENTITY = "AudioObject"
  BASE = "/audio-objects"

  def setup
    @server = T.get_server
  end

  def create_item
    payload = T.build_payload(@server, ENTITY)
    r = T.request_json(@server, "POST", BASE, payload)
    raise "POST #{BASE} expected 201, got #{r["status"]}: #{r["raw"]}" if r["status"] != 201
    r["body"]
  end

  def test_create_returns_201_with_type_and_id
    item = create_item
    assert_equal ENTITY, item["@type"]
    assert_equal "https://schema.org", item["@context"]
    assert item["id"]
  end

  def test_get_by_id_returns_200_with_etag
    item = create_item
    r = T.request_json(@server, "GET", "#{BASE}/#{item["id"]}")
    assert_equal 200, r["status"]
    assert r["headers"]["etag"]
  end

  def test_list_returns_items_total_envelope
    create_item
    r = T.request_json(@server, "GET", BASE)
    assert_equal 200, r["status"]
    assert_kind_of Array, r["body"]["items"]
    assert_kind_of Integer, r["body"]["total"]
  end

  def test_put_partial_update_returns_200
    item = create_item
    partial = T.build_payload(@server, ENTITY, partial: true)
    r = T.request_json(@server, "PUT", "#{BASE}/#{item["id"]}", partial)
    assert_equal 200, r["status"], "PUT expected 200, got #{r["status"]}: #{r["raw"]}"
  end

  def test_delete_returns_204_then_404
    item = create_item
    d = T.request_json(@server, "DELETE", "#{BASE}/#{item["id"]}")
    assert_equal 204, d["status"]
    g = T.request_json(@server, "GET", "#{BASE}/#{item["id"]}")
    assert_equal 404, g["status"]
  end

  def test_invalid_uuid_returns_400_invalid_id
    r = T.request_json(@server, "GET", "#{BASE}/not-a-uuid")
    assert_equal 400, r["status"]
    assert_equal "INVALID_ID", r["body"]["error"]
  end

  def test_unknown_id_returns_404_not_found
    r = T.request_json(@server, "GET", "#{BASE}/00000000-0000-0000-0000-000000000000")
    assert_equal 404, r["status"]
    assert_equal "NOT_FOUND", r["body"]["error"]
  end

  def test_pagination_limit_offset_honour_total
    create_item
    create_item
    create_item
    r = T.request_json(@server, "GET", "#{BASE}?limit=2&offset=0")
    assert_operator r["body"]["total"], :>=, 3
    assert_operator r["body"]["items"].length, :<=, 2
  end

  def test_sort_by_name_accepted
    r = T.request_json(@server, "GET", "#{BASE}?sort=name&order=asc")
    assert_equal 200, r["status"]
  end

  def test_unknown_sort_field_rejected_with_400
    r = T.request_json(@server, "GET", "#{BASE}?sort=definitely-not-a-field")
    assert_equal 400, r["status"]
  end

  def test_filter_on_text_field_name_returns_matches
    created = create_item
    needle = (created["name"] || "").to_s[0, 4]
    return if needle.empty?
    r = T.request_json(@server, "GET", "#{BASE}?name=#{CGI.escape(needle)}")
    found = r["body"]["items"].any? { |i| i["id"] == created["id"] }
    assert found, "created item not found via filter"
  end

  def test_stale_if_match_on_put_returns_412
    item = create_item
    r = T.request_json(@server, "PUT", "#{BASE}/#{item["id"]}", {}, headers: { "If-Match" => '"0000000000000000"' })
    assert_equal 412, r["status"]
  end

  def test_cors_preflight_returns_204_with_allow_headers
    r = T.request_json(@server, "OPTIONS", BASE, headers: { "Origin" => "https://example.com", "Access-Control-Request-Method" => "POST" })
    assert_equal 204, r["status"]
    assert_equal "*", r["headers"]["access-control-allow-origin"]
  end

  def test_deeply_nested_json_body_rejected_with_400
    depth = 2000
    deep = "[" * depth + "]" * depth
    r = T.request_json(@server, "POST", BASE, nil, raw_body: deep)
    assert_equal 400, r["status"]
    assert_equal "INVALID_JSON", r["body"]["error"]
  end

  def test_leading_trailing_whitespace_trimmed_on_create
    payload = T.build_payload(@server, ENTITY)
    payload["name"] = "  trimmed value  "
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, r["status"], "expected 201: #{r["raw"]}"
    assert_equal "trimmed value", r["body"]["name"]
  end

  def test_control_characters_stripped_on_create
    payload = T.build_payload(@server, ENTITY)
    payload["name"] = "clean\u0000\u0007ed"
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, r["status"], "expected 201: #{r["raw"]}"
    assert_equal "cleaned", r["body"]["name"]
  end

  def test_value_over_max_length_rejected_with_400
    payload = T.build_payload(@server, ENTITY)
    payload["name"] = "a" * 257
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 400, r["status"]
    assert_equal "VALIDATION_ERROR", r["body"]["error"]
  end

  def test_value_at_max_length_accepted
    payload = T.build_payload(@server, ENTITY)
    payload["name"] = "a" * 256
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, r["status"], "expected 201: #{r["raw"]}"
  end

  def test_multiline_field_description_keeps_newlines
    payload = T.build_payload(@server, ENTITY)
    payload["description"] = "first line\nsecond line"
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, r["status"], "expected 201: #{r["raw"]}"
    assert_equal "first line\nsecond line", r["body"]["description"]
  end

  def test_single_line_field_name_strips_newlines
    payload = T.build_payload(@server, ENTITY)
    payload["name"] = "first\nsecond"
    r = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, r["status"], "expected 201: #{r["raw"]}"
    assert_equal "firstsecond", r["body"]["name"]
  end

  def test_get_by_id_embeds_creator_object_list_stays_flat
    payload = T.build_payload(@server, ENTITY, partial: true)
    created = T.request_json(@server, "POST", BASE, payload)["body"]

    ref_id = created["creator"]
    assert_kind_of String, ref_id

    got = T.request_json(@server, "GET", "#{BASE}/#{created["id"]}")["body"]
    embedded = got["creator"]
    assert_kind_of Hash, embedded
    assert_equal "Person", embedded["@type"]
    assert_equal ref_id, embedded["id"]

    listed = T.request_json(@server, "GET", "#{BASE}?limit=100")["body"]
    in_list = listed["items"].find { |i| i["id"] == created["id"] }
    assert_kind_of String, in_list["creator"]
  end

  def test_get_by_id_leaves_dangling_creator_ref_as_uuid
    dangling = "00000000-0000-0000-0000-000000000000"
    payload = T.build_payload(@server, ENTITY, partial: true)
    payload["creator"] = dangling
    created = T.request_json(@server, "POST", BASE, payload)["body"]
    got = T.request_json(@server, "GET", "#{BASE}/#{created["id"]}")["body"]
    assert_equal dangling, got["creator"]
  end

  def test_fresh_etag_from_get_satisfies_if_match_on_put_then_delete
    payload = T.build_payload(@server, ENTITY, partial: true)
    created = T.request_json(@server, "POST", BASE, payload)["body"]

    got = T.request_json(@server, "GET", "#{BASE}/#{created["id"]}")
    assert_equal 200, got["status"]
    etag = got["headers"]["etag"]
    assert etag

    # The observable ETag names the record version: a conditional GET with it is a 304.
    not_modified = T.request_json(@server, "GET", "#{BASE}/#{created["id"]}", headers: { "If-None-Match" => etag })
    assert_equal 304, not_modified["status"]

    # The honest fresh path: PUT with the ETag the GET handed out succeeds.
    put = T.request_json(@server, "PUT", "#{BASE}/#{created["id"]}", {}, headers: { "If-Match" => etag })
    assert_equal 200, put["status"], "PUT with fresh If-Match expected 200, got #{put["status"]}: #{put["raw"]}"

    # The PUT response carries the new record version; DELETE with it succeeds.
    put_etag = put["headers"]["etag"]
    assert put_etag
    del = T.request_json(@server, "DELETE", "#{BASE}/#{created["id"]}", headers: { "If-Match" => put_etag })
    assert_equal 204, del["status"]
  end

  def test_duplicate_unique_key_on_create_rejected
    payload = T.build_payload(@server, ENTITY)
    first = T.request_json(@server, "POST", BASE, payload)
    assert_equal 201, first["status"], "first create expected 201, got #{first["status"]}: #{first["raw"]}"
    second = T.request_json(@server, "POST", BASE, payload)
    assert_equal 400, second["status"]
    assert_equal "VALIDATION_ERROR", second["body"]["error"]
  end

  def test_update_without_changing_unique_key_succeeds
    item = create_item
    key = ["contentUrl"]
    echo = {}
    key.each { |f| echo[f] = item[f] }
    r = T.request_json(@server, "PUT", "#{BASE}/#{item["id"]}", echo)
    assert_equal 200, r["status"], "self-update expected 200, got #{r["status"]}: #{r["raw"]}"
  end

  def test_update_to_collide_with_other_unique_key_rejected
    a = create_item
    b = create_item
    key = ["contentUrl"]
    collide = {}
    key.each { |f| collide[f] = a[f] }
    r = T.request_json(@server, "PUT", "#{BASE}/#{b["id"]}", collide)
    assert_equal 400, r["status"]
    assert_equal "VALIDATION_ERROR", r["body"]["error"]
  end
end
