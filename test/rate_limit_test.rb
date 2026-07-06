require_relative "test_helper"

# Reads and writes have independent per-IP windows. Each test starts a server with
# one bucket set low and the other effectively unlimited, then drives requests until
# the limiter trips. Exact counts are not asserted — server startup spends a request
# or two — only that limiting eventually engages after at least one request is
# admitted, and that the rejection carries the 429 envelope and a sane Retry-After.
# Requests go out unauthenticated: the limiter runs before auth, so they still count.
class RateLimitTest < Minitest::Test
  BASE = "/blog-postings"

  def test_writes_over_limit_get_429_and_retry_after
    server = T.start_server(env: { "RATE_LIMIT_WRITE_PER_MINUTE" => "5", "RATE_LIMIT_READ_PER_MINUTE" => "1000000" })
    begin
      admitted = 0
      limited = nil
      40.times do
        r = T.request_json(server, "POST", BASE, nil, raw_body: "{}", no_auth: true)
        if r["status"] == 429
          limited = r
          break
        end
        admitted += 1
      end
      assert_operator admitted, :>=, 1, "at least one write should be admitted before limiting"
      refute_nil limited, "writes should eventually be rate limited"
      retry_after = limited["headers"]["retry-after"].to_i
      assert (1..60).cover?(retry_after), "Retry-After out of range: #{limited["headers"]["retry-after"]}"
      assert_equal 429, limited["status"]
      assert_equal "TOO_MANY_REQUESTS", limited["body"]["error"]
    ensure
      server.stop
    end
  end

  def test_reads_have_their_own_window
    server = T.start_server(env: { "RATE_LIMIT_READ_PER_MINUTE" => "120", "RATE_LIMIT_WRITE_PER_MINUTE" => "1000000" })
    begin
      admitted = 0
      limited = nil
      200.times do
        r = T.request_json(server, "GET", BASE, nil, no_auth: true)
        if r["status"] == 429
          limited = r
          break
        end
        admitted += 1
      end
      assert_operator admitted, :>=, 1, "at least one read should be admitted before limiting"
      refute_nil limited, "reads should eventually be rate limited"
      retry_after = limited["headers"]["retry-after"].to_i
      assert (1..60).cover?(retry_after)
      assert_equal 429, limited["status"]
      assert_equal "TOO_MANY_REQUESTS", limited["body"]["error"]
    ensure
      server.stop
    end
  end
end
