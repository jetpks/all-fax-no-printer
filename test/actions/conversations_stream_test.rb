# frozen_string_literal: true

require_relative "action_test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/conversations/stream_fanout"
require "space/server/conversations/stream_key"

class ConversationsStreamActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "stream-owner", username: "stream_owner"]
    @other = Factory[:user, github_uid: "stream-other", username: "stream_other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def mint_token(user, name = "cli")
    Space::Server::App["repos.api_tokens_repo"].create(user_id: user.id, name: name)
  end

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end

  # --- authz posture ------------------------------------------------------------------

  def test_stream_missing_conversation_returns_404
    status, _, _ = get("/conversations/99999/stream")
    assert_equal 404, status
  end

  def test_stream_anon_on_invisible_returns_401
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/conversations/#{conv.id}/stream")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_stream_anon_on_published_returns_200
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: true]
    status, headers, _ = get_stream("/conversations/#{conv.id}/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
  end

  def test_stream_authenticated_non_owner_returns_403
    sign_in(@other)
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/conversations/#{conv.id}/stream")
    assert_equal 403, status
    assert parse_json(body).key?("error")
  end

  def test_stream_owner_returns_sse_headers
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    status, headers, _ = get_stream("/conversations/#{conv.id}/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    assert_equal "no-cache", headers["cache-control"]
  end

  def test_stream_bearer_wrong_token_returns_401
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    env = Rack::MockRequest.env_for("/conversations/#{conv.id}/stream", "REQUEST_METHOD" => "GET")
    env["HTTP_AUTHORIZATION"] = "Bearer wrong-token"
    status, _, body = app.call(env)
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_stream_bearer_owner_returns_sse_headers
    secret, = mint_token(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1, published: false]
    env = Rack::MockRequest.env_for("/conversations/#{conv.id}/stream", "REQUEST_METHOD" => "GET")
    env["HTTP_AUTHORIZATION"] = "Bearer #{secret}"
    status, headers, _ = app.call(env)
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
  end

  # --- replay mechanics -----------------------------------------------------------------

  def test_stream_backlog_emits_sse_events
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","text":"hello"}')
      redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      _, _, body = get_stream("/conversations/#{conv.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      assert_match "id:", text
      assert_match "data:", text
      assert chunks.any? { |c| c.include?("text_delta") }, "Expected text_delta event"
      assert chunks.any? { |c| c.include?("conversation_complete") }, "Expected conversation_complete event"
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  def test_stream_last_event_id_skips_earlier_entries
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      first_entry = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":1}')
      _           = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":2}')
      _           = redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      # Resume from first_entry — should only deliver the 2nd and the terminal
      _, _, body = get_stream("/conversations/#{conv.id}/stream",
                              extra_env: { "HTTP_LAST_EVENT_ID" => first_entry })
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      refute_match(/seq.*1/, text)
      assert_match "seq\":2", text
      assert_match "conversation_complete", text
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  def test_stream_live_tail_delivers_entries_via_fanout
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      _, _, body = get_stream("/conversations/#{conv.id}/stream")
      chunks = []
      mock_stream = MockStream.new(chunks)

      body_task = Async do
        begin
          body.call(mock_stream)
        rescue
        end
      end

      # Sleep briefly to let XREAD BLOCK register in Redis before XADD fires.
      sleep 0.05

      redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","text":"live"}')
      redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      body_task.wait
      text = chunks.join
      assert_match "text_delta", text
      assert_match "conversation_complete", text
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  def test_stream_heartbeat_fanout_pings_between_events
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    # Heartbeat constant swapped short — the action reads it at queue-pop time,
    # so the production 15s posture is unchanged while the test cycles fast.
    fanout_class = Space::Server::Conversations::StreamFanout
    original     = fanout_class::HEARTBEAT_SECONDS
    fanout_class.send(:remove_const, :HEARTBEAT_SECONDS)
    fanout_class.const_set(:HEARTBEAT_SECONDS, 0.1)
    begin
      Sync do
        redis_client = Async::Redis::Client.new(redis_endpoint)
        key = Space::Server::Conversations::StreamKey.for(conv.id)
        redis_client.del(key)

        # An entry with no terminal marker: the stream stays open and the
        # heartbeat must fire between the backlog and the tail.
        redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","seq":0}')

        _, _, body = get_stream("/conversations/#{conv.id}/stream")
        chunks = []
        mock_stream = MockStream.new(chunks)

        body_task = Async do
          begin
            body.call(mock_stream)
          rescue
          end
        end

        # Wait for the backlog + a couple of heartbeat cycles.
        sleep 1
        body_task.stop
        body_task.wait rescue nil

        text = chunks.join
        assert_match "text_delta", text
        assert_match ": ping", text, "heartbeat comment must arrive between events"
      ensure
        redis_client&.close
        Space::Server::Conversations::StreamFanout.stop(conv.id)
      end
    ensure
      fanout_class.send(:remove_const, :HEARTBEAT_SECONDS)
      fanout_class.const_set(:HEARTBEAT_SECONDS, original)
    end
  end

  # --- db_replay fallback (Redis expired + terminal conversation) --------------------------

  def test_stream_db_fallback_replays_messages_when_redis_expired
    sign_in(@owner)
    conversations_repo = Space::Server::App["repos.conversations_repo"]
    messages_repo      = Space::Server::App["repos.messages_repo"]

    conv = conversations_repo.create(
      user_id: @owner.id, status: 2, published: false,
      created_at: Time.now, updated_at: Time.now
    )
    messages_repo.create(
      conversation_id: conv.id, role: "assistant",
      content: [{ "type" => "text", "text" => "hello from db" }],
      position: 0, published: false,
      created_at: Time.now, updated_at: Time.now
    )

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      _, _, body = get_stream("/conversations/#{conv.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      assert_match "conversation_complete", text
      assert_match "hello from db", text
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  # AC2 seam test: db_replay must not emit ids that alias real stream positions.
  # Seeds one real Redis entry with no terminal marker (a partial tail), so
  # the response streams it via XRANGE (a real id) then falls through to
  # db_replay for the rest. The client's Last-Event-ID after consuming this
  # response is therefore the real entry's id — db_replay emits no id: fields
  # of its own, so it never advances past it. Reconnecting with that id must
  # not re-deliver the real Redis entry (a fabricated db_replay id like "0-1"
  # sorts below every real, timestamp-based stream id, so `XRANGE ((0-1`
  # against the real stream would replay it in full).
  def test_stream_db_replay_omits_ids_so_reconnect_does_not_replay_redis_stream
    sign_in(@owner)
    conversations_repo = Space::Server::App["repos.conversations_repo"]
    messages_repo      = Space::Server::App["repos.messages_repo"]

    conv = conversations_repo.create(
      user_id: @owner.id, status: 2, published: false,
      created_at: Time.now, updated_at: Time.now
    )
    messages_repo.create(
      conversation_id: conv.id, role: "assistant",
      content: [{ "type" => "text", "text" => "hello from db" }],
      position: 0, published: false,
      created_at: Time.now, updated_at: Time.now
    )

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      real_id = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":"real-tail"}')

      _, _, body = get_stream("/conversations/#{conv.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)
      text = chunks.join

      id_lines = text.lines.select { |l| l.start_with?("id:") }
      assert_equal 1, id_lines.size, "only the real Redis entry may carry an id: field"
      assert_includes id_lines.first, real_id

      # Reconnect with the client's post-db_replay Last-Event-ID — must not
      # receive a duplicate full replay of the real Redis entry.
      _, _, body2 = get_stream("/conversations/#{conv.id}/stream", extra_env: { "HTTP_LAST_EVENT_ID" => real_id })
      chunks2 = collect_sse_chunks(body2, timeout: 5)
      text2 = chunks2.join

      refute_match(/seq.*real-tail/, text2)
      assert_match "hello from db", text2
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  # Terminal conversations (failed, zero-message) must still close the stream.
  def test_stream_failed_conversation_without_messages_terminates
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 3, published: false, turns_count: 0]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      _, _, body = get_stream("/conversations/#{conv.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)
      assert chunks.any? { |c| c.include?("conversation_complete") },
        "failed conversation must terminate with conversation_complete"
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  # --- ?tail= message windowing --------------------------------------------------------

  # Seeds `count` messages (message_start + delta) plus a terminal event; the
  # data JSONs carry the message index so the window boundary is assertable.
  def seed_messages(redis_client, key, count)
    count.times do |i|
      redis_client.xadd(key, "*", "type", "message_start", "data", %({"type":"message_start","seq":#{i}}))
      redis_client.xadd(key, "*", "type", "text_delta", "data", %({"type":"text_delta","seq":#{i}}))
    end
    redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')
  end

  def sse_data(chunks)
    chunks.join.scan(/^data: (.+)$/).map { |(data)| JSON.parse(data) }
  end

  def test_stream_tail_replays_only_the_last_n_messages
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      seed_messages(redis_client, key, 3)

      _, _, body = get_stream("/conversations/#{conv.id}/stream?tail=2")
      chunks = collect_sse_chunks(body, timeout: 5)

      seqs = sse_data(chunks).map { |d| d["seq"] }.compact
      assert_equal [1, 1, 2, 2], seqs, "the last 2 messages only — message 0 is cut"
      assert chunks.any? { |c| c.include?("conversation_complete") }, "window ends at the stream end (terminal included)"
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  def test_stream_tail_ignored_on_last_event_id_resume
    sign_in(@owner)
    conv = Factory[:conversation, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)
      first_entry = redis_client.xadd(key, "*", "type", "message_start", "data", %({"type":"message_start","seq":0}))
      seed_messages(redis_client, key, 2)

      # Resume from the first entry: everything after the cursor, tail ignored.
      _, _, body = get_stream("/conversations/#{conv.id}/stream?tail=1",
                              extra_env: { "HTTP_LAST_EVENT_ID" => first_entry })
      chunks = collect_sse_chunks(body, timeout: 5)

      seqs = sse_data(chunks).map { |d| d["seq"] }.compact
      assert_includes seqs, 0, "reconnect replays everything after its cursor — no tail windowing"
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end

  def test_stream_tail_windows_the_db_replay_fallback_too
    sign_in(@owner)
    conversations_repo = Space::Server::App["repos.conversations_repo"]
    messages_repo      = Space::Server::App["repos.messages_repo"]

    conv = conversations_repo.create(
      user_id: @owner.id, status: 2, published: false,
      created_at: Time.now, updated_at: Time.now
    )
    3.times do |i|
      messages_repo.create(
        conversation_id: conv.id, role: "user",
        content: [{ "type" => "text", "text" => "db message #{i}" }],
        position: i, published: false,
        created_at: Time.now, updated_at: Time.now
      )
    end

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      _, _, body = get_stream("/conversations/#{conv.id}/stream?tail=2")
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      refute_match "db message 0", text, "db_replay honors the tail window"
      assert_match "db message 1", text
      assert_match "db message 2", text
      assert_match "conversation_complete", text
    ensure
      redis_client&.close
      Space::Server::Conversations::StreamFanout.stop(conv.id)
    end
  end
end
