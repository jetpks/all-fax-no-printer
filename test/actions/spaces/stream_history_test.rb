# frozen_string_literal: true

require_relative "../action_test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/conversations/stream_key"

# Upward history pagination for the space live log: GET
# /spaces/:id/stream/history?before=<sse_id>&limit=N returns the at-most-N
# messages strictly before the envelope id, merged across the space's
# conversations chronologically with the SAME envelope the SSE stream
# carries, plus a `more` flag for the next page.
class SpacesStreamHistoryActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "space-hist-owner", username: "space_hist_owner"]
    @other = Factory[:user, github_uid: "space-hist-other", username: "space_hist_other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis::LocalEndpoint
  end

  # --- authz posture ------------------------------------------------------------------

  def test_history_missing_space_returns_404
    status, _, _ = get("/spaces/99999/stream/history")
    assert_equal 404, status
  end

  def test_history_anon_returns_401
    space = Factory[:space, user_id: @owner.id]
    status, _, body = get("/spaces/#{space.id}/stream/history?before=1:1-1")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_history_authenticated_non_owner_returns_403
    sign_in(@other)
    space = Factory[:space, user_id: @owner.id]
    status, _, body = get("/spaces/#{space.id}/stream/history?before=1:1-1")
    assert_equal 403, status
    assert parse_json(body).key?("error")
  end

  # --- merged windowing ----------------------------------------------------------------

  def test_history_merges_conversations_chronologically_with_envelope
    sign_in(@owner)
    space  = Factory[:space, user_id: @owner.id]
    conv_a = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                     agent_role: "coordinator", agent_name: "architect-coordinator"]
    conv_b = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                     agent_role: nil, agent_name: "Navi the Navigator"]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key_a = Space::Server::Conversations::StreamKey.for(conv_a.id)
      key_b = Space::Server::Conversations::StreamKey.for(conv_b.id)
      [key_a, key_b].each { |k| redis_client.del(k) }

      # Conv A's message at ms 1000, conv B's at ms 2000 (distinct ms —
      # per-stream seq counters aren't comparable across conversations).
      a_ms = redis_client.xadd(key_a, "1776700000000-0", "type", "message_start", "data", %({"type":"message_start","conv":0,"seq":0}))
      redis_client.xadd(key_a, "1776700000000-1", "type", "text_delta", "data", %({"type":"text_delta","conv":0,"seq":0}))
      b_ms = redis_client.xadd(key_b, "1776700001000-0", "type", "message_start", "data", %({"type":"message_start","conv":1,"seq":0}))
      redis_client.xadd(key_b, "1776700001000-1", "type", "text_delta", "data", %({"type":"text_delta","conv":1,"seq":0}))

      # Before = conv B's message_start: candidate = conv A's message only
      # (B's own bound is exact; A's is same-ms-strict, ms 1000 < 2000).
      status, _, body = get("/spaces/#{space.id}/stream/history?before=#{conv_b.id}:#{b_ms}")
      assert_equal 200, status

      json = parse_json(body)
      assert_equal false, json["more"]
      convs = json["events"].map { |e| e.dig("data", "conversation_id") }
      assert_equal [conv_a.id, conv_a.id], convs, "only conv A's message is below the bound"

      # Envelope parity with the SSE stream: id form and merged keys.
      first = json["events"].first
      assert_equal "#{conv_a.id}:#{a_ms}", first["id"]
      assert_equal "architect-coordinator", first["data"]["tag"]
      assert_equal "coordinator", first["data"]["agent_role"]
      assert_equal "architect-coordinator", first["data"]["agent_name"]
    ensure
      redis_client&.close
    end
  end

  def test_history_without_before_defaults_to_merged_tail
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      4.times do |i|
        redis_client.xadd(key, "*", "type", "message_start", "data", %({"type":"message_start","seq":#{i}}))
        redis_client.xadd(key, "*", "type", "text_delta", "data", %({"type":"text_delta","seq":#{i}}))
      end

      status, _, body = get("/spaces/#{space.id}/stream/history?limit=2")
      json = parse_json(body)
      seqs = json["events"].map { |e| e.dig("data", "seq") }.compact
      assert_equal [2, 2, 3, 3], seqs, "no before → the last `limit` messages of everything"
      assert_equal true, json["more"]
    ensure
      redis_client&.close
    end
  end
end
