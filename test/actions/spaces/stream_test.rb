# frozen_string_literal: true

require_relative "../action_test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/conversations/stream_key"
require "space/server/spaces/stream_mux"

# The phone observation deck feed: GET /spaces/:id/stream muxes the space's
# conversations' display streams into one long-lived SSE response. The stream
# is a pure live tail — conversation_complete is ordinary — so behavioral tests
# drive body.call in an Async task, poll chunks, then stop the task (the frozen
# event contract is asserted in the envelope/heartbeat/rescan tests below).
class SpacesStreamActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "space-stream-owner", username: "space_stream_owner"]
    @other = Factory[:user, github_uid: "space-stream-other", username: "space_stream_other"]
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

  # Swap a frozen timing constant short (remove_const/const_set, as in
  # conversations_stream_test.rb); production posture restored afterwards.
  def with_swapped_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end

  # Run the SSE body against a MockStream in a stoppable task.
  def stream_body_task(body, chunks)
    mock_stream = MockStream.new(chunks)
    Async do
      begin
        body.call(mock_stream)
      rescue
      end
    end
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    until yield
      raise "condition not met within #{timeout}s" if Time.now > deadline
      sleep 0.02
    end
  end

  # Parsed SSE events: [[id, data_hash], …] in emission order.
  def sse_events(chunks)
    chunks.join.scan(/^id: (.+)\ndata: (.+)$/).map do |id, data|
      [id, JSON.parse(data)]
    end
  end

  def entry_position(sse_id)
    sse_id.split(":").last.split("-").map(&:to_i)
  end

  # --- authz posture -------------------------------------------------------------------

  def test_stream_missing_space_returns_404
    status, _, _ = get("/spaces/99999/stream")
    assert_equal 404, status
  end

  def test_stream_anon_on_owned_space_returns_401
    space = Factory[:space, user_id: @owner.id]
    status, _, body = get("/spaces/#{space.id}/stream")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_stream_signed_in_non_owner_returns_403
    sign_in(@other)
    space = Factory[:space, user_id: @owner.id]
    status, _, body = get("/spaces/#{space.id}/stream")
    assert_equal 403, status
    assert parse_json(body).key?("error")
  end

  def test_stream_owner_returns_sse_headers
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]
    status, headers, _ = get_stream("/spaces/#{space.id}/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    assert_equal "no-cache", headers["cache-control"]
  end

  def test_stream_bearer_owner_returns_sse_headers
    secret, = mint_token(@owner)
    space = Factory[:space, user_id: @owner.id]
    env = Rack::MockRequest.env_for("/spaces/#{space.id}/stream", "REQUEST_METHOD" => "GET")
    env["HTTP_AUTHORIZATION"] = "Bearer #{secret}"
    status, headers, _ = app.call(env)
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
  end

  # --- backlog: envelope merge + cross-conversation chronology -------------------------

  def test_stream_backlog_from_two_conversations_envelope_merged_chronological
    sign_in(@owner)
    space  = Factory[:space, user_id: @owner.id]
    conv_a = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: "architect-coordinator", agent_name: "Coordinator Prime"]
    conv_b = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: nil, agent_name: "Navi the Navigator"]
    conv_c = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                    agent_role: nil, agent_name: nil]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key_a = Space::Server::Conversations::StreamKey.for(conv_a.id)
      key_b = Space::Server::Conversations::StreamKey.for(conv_b.id)
      key_c = Space::Server::Conversations::StreamKey.for(conv_c.id)
      [key_a, key_b, key_c].each { |k| redis_client.del(k) }

      _, _, body = get_stream("/spaces/#{space.id}/stream")
      chunks = []
      body_task = stream_body_task(body, chunks)

      # Interleave entries across the three conversations; whether each lands in
      # the backlog XRANGE or the live tail, emission order must stay
      # chronological (the backlog is numerically sorted, live entries are newer).
      redis_client.xadd(key_a, "*", "type", "text_delta",       "data", '{"type":"text_delta","text":"a1"}')
      redis_client.xadd(key_b, "*", "type", "message_complete", "data", '{"type":"message_complete"}')
      redis_client.xadd(key_c, "*", "type", "text_delta",       "data", '{"type":"text_delta","text":"c1"}')
      redis_client.xadd(key_a, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      wait_until { sse_events(chunks).size >= 4 }
      body_task.stop
      body_task.wait rescue nil

      events = sse_events(chunks)
      assert_equal 4, events.size, "each backlog entry delivered exactly once"

      events.each do |id, data|
        assert_match(/\A\d+:\d+-\d+\z/, id, "id: must be <conversation_id>:<entry_id>")
        assert_includes [conv_a.id, conv_b.id, conv_c.id].map(&:to_s),
                        id.split(":").first, "id must embed a real conversation id"
        %w[conversation_id agent_role agent_name tag type].each do |key|
          assert data.key?(key), "envelope/event must include '#{key}'"
        end
        assert_kind_of Integer, data["conversation_id"]
        assert_kind_of String, data["tag"]
      end

      # Frozen tag map: role abbrev beats truncated name beats conv fallback.
      by_conversation = events.group_by { |id, _| id.split(":").first }
      assert_equal "coord", by_conversation[conv_a.id.to_s].first[1]["tag"]
      assert_equal "Navi the N", by_conversation[conv_b.id.to_s].first[1]["tag"]
      assert_equal "conv-#{conv_c.id}", by_conversation[conv_c.id.to_s].first[1]["tag"]
      assert_equal conv_a.id, by_conversation[conv_a.id.to_s].first[1]["conversation_id"]
      assert_equal "architect-coordinator", by_conversation[conv_a.id.to_s].first[1]["agent_role"]
      assert_equal "Coordinator Prime", by_conversation[conv_a.id.to_s].first[1]["agent_name"]

      # Numeric (ms, seq) sort across conversations — string sort is wrong at seq ≥ 10.
      positions = events.map { |id, _| entry_position(id) }
      assert_equal positions, positions.sort, "backlog must arrive chronologically"
    ensure
      redis_client&.close
      Space::Server::Spaces::StreamMux.stop(space.id)
    end
  end

  # --- Last-Event-ID exclusive resume --------------------------------------------------

  def test_stream_last_event_id_exclusive_resume
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Space::Server::Conversations::StreamKey.for(conv.id)
      redis_client.del(key)

      first_entry  = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","seq":1}')
      _            = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","seq":2}')
      _            = redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      # Resume from the first entry's composite id — it and nothing before it
      # must be replayed; everything after must be.
      _, _, body = get_stream("/spaces/#{space.id}/stream",
                              extra_env: { "HTTP_LAST_EVENT_ID" => "#{conv.id}:#{first_entry}" })
      chunks = []
      body_task = stream_body_task(body, chunks)

      wait_until { sse_events(chunks).size >= 2 }
      body_task.stop
      body_task.wait rescue nil

      events = sse_events(chunks)
      seqs = events.map { |_, data| data["seq"] }.compact
      refute_includes seqs, 1, "replayed range is exclusive at the Last-Event-ID"
      assert_includes seqs, 2
      assert_match "conversation_complete", chunks.join
    ensure
      redis_client&.close
      Space::Server::Spaces::StreamMux.stop(space.id)
    end
  end

  # --- conversation_complete is an ordinary event --------------------------------------

  def test_stream_conversation_complete_is_not_terminal
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]
    conv_a = Factory[:conversation, user_id: @owner.id, space_id: space.id]
    conv_b = Factory[:conversation, user_id: @owner.id, space_id: space.id]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key_a = Space::Server::Conversations::StreamKey.for(conv_a.id)
      key_b = Space::Server::Conversations::StreamKey.for(conv_b.id)
      [key_a, key_b].each { |k| redis_client.del(k) }

      redis_client.xadd(key_a, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

      _, _, body = get_stream("/spaces/#{space.id}/stream")
      chunks = []
      body_task = stream_body_task(body, chunks)

      wait_until { sse_events(chunks).any? { |_, d| d["type"] == "conversation_complete" } }
      assert_equal 1, sse_events(chunks).size, "no terminal break — the mux keeps running"

      # The stream survived conversation_complete: conversation B still delivers.
      redis_client.xadd(key_b, "*", "type", "text_delta", "data", '{"type":"text_delta","text":"still alive"}')
      wait_until { sse_events(chunks).any? { |_, d| d["text"] == "still alive" } }
      body_task.stop
      body_task.wait rescue nil
    ensure
      redis_client&.close
      Space::Server::Spaces::StreamMux.stop(space.id)
    end
  end

  def test_stream_heartbeat_continues_after_complete
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]
    conv  = Factory[:conversation, user_id: @owner.id, space_id: space.id]

    # Heartbeat constant swapped short — the action reads it at queue-pop time,
    # so the production 15s posture is unchanged while the test cycles fast.
    with_swapped_const(Space::Server::Spaces::StreamMux, :HEARTBEAT_SECONDS, 0.1) do
      Sync do
        redis_client = Async::Redis::Client.new(redis_endpoint)
        key = Space::Server::Conversations::StreamKey.for(conv.id)
        redis_client.del(key)

        redis_client.xadd(key, "*", "type", "conversation_complete", "data", '{"type":"conversation_complete"}')

        _, _, body = get_stream("/spaces/#{space.id}/stream")
        chunks = []
        body_task = stream_body_task(body, chunks)

        wait_until { sse_events(chunks).any? { |_, d| d["type"] == "conversation_complete" } }
        wait_until(timeout: 5) { chunks.join.include?(": ping") }
        body_task.stop
        body_task.wait rescue nil

        text = chunks.join
        assert_match "conversation_complete", text
        assert_match ": ping", text, "heartbeat pings must continue after conversation_complete"
      ensure
        redis_client&.close
        Space::Server::Spaces::StreamMux.stop(space.id)
      end
    end
  end

  # --- rescan adoption -----------------------------------------------------------------

  def test_stream_rescan_adopts_conversation_created_after_connect
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id]

    with_swapped_const(Space::Server::Spaces::StreamMux, :RESCAN_SECONDS, 0.2) do
      Sync do
        redis_client = Async::Redis::Client.new(redis_endpoint)

        _, _, body = get_stream("/spaces/#{space.id}/stream")
        chunks = []
        body_task = stream_body_task(body, chunks)

        # A conversation (and its stream key) created after the mux started.
        sleep 0.3
        conv = Factory[:conversation, user_id: @owner.id, space_id: space.id,
                       agent_role: "architect-builder", agent_name: "bld-lane", updated_at: Time.now]
        key = Space::Server::Conversations::StreamKey.for(conv.id)
        redis_client.del(key)

        # Adoption takes the next rescan cycle and adopts with cursor "$" — the
        # entry must be added after adoption to be live-delivered.
        sleep 0.4
        redis_client.xadd(key, "*", "type", "text_delta", "data", '{"type":"text_delta","text":"adopted"}')

        event = nil
        wait_until do
          event = sse_events(chunks).find { |_, d| d["text"] == "adopted" }
        end
        body_task.stop
        body_task.wait rescue nil

        _, data = event
        assert_equal conv.id, data["conversation_id"]
        assert_equal "architect-builder", data["agent_role"]
        assert_equal "bld-lane", data["agent_name"]
        assert_equal "bld", data["tag"]
      ensure
        redis_client&.close
        Space::Server::Spaces::StreamMux.stop(space.id)
      end
    end
  end
end
