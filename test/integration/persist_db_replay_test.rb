# frozen_string_literal: true

# Real-HTTP + real-PG + real-Redis integration test for the DB-replay path (DoD #3).
#
# Ingests a multi-message fixture (text, tool_use, tool_result block types) over real
# HTTP so the Persistor runs for real.  Then clears the Redis stream key to simulate
# TTL expiry and asserts that GET /conversations/:id/stream replays from the DB via
# db_replay.
#
# AC-P3 faithfulness: reverting stream.rb's db_replay cutover to a no-op causes the
# stream body proc to enter the queue loop and never emit conversation_complete
# within the test timeout, making the assert_match below FAIL.

require_relative "../test_helper"
require "rack/mock"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/rack/adapter"
require "protocol/http/body/buffered"
require "space/server/conversations/stream_fanout"
require "space/server/conversations/stream_key"

Space::Server::App.start(:redis)

class PersistDbReplayTest < Minitest::Test
  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_streaming_session.jsonl"))
  FIXTURE_EVENT_COUNT = 23  # confirmed: pi parser produces 23 events from pi_streaming_session.jsonl

  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:messages, :conversations, :users].each { |t| conn[t].delete }
    @user  = Factory[:user]
    @redis = Space::Server::App["redis"]
    # Machine auth is sat_-only: mint a real bearer for the harness user.
    @bearer, = Space::Server::App["repos.api_tokens_repo"].create(user_id: @user.id, name: "integration")
  end

  def test_ingest_persists_db_and_stream_replays_after_redis_expiry
    messages_repo = Space::Server::App["repos.messages_repo"]
    port          = 50100 + rand(400)
    endpoint      = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

    Sync do |task|
      server_task = task.async do
        Async::HTTP::Server.new(Protocol::Rack::Adapter.new(Space::Server::App), endpoint).run
      rescue => _e
        nil
      end

      begin
        task.sleep(0.3)
        client = Async::HTTP::Client.new(endpoint)

        task.with_timeout(30) do
          # ── Phase 1: Ingest via real HTTP (terminal header → :completed) ──

          headers  = Protocol::HTTP::Headers.new([
            ["content-type",  "application/x-ndjson"],
            ["authorization", "Bearer #{@bearer}"],
            ["x-session-complete", "true"]
          ])
          body     = Protocol::HTTP::Body::Buffered.wrap(FIXTURE_JSONL)
          response = client.post("/conversations/ingest", headers, body)
          raw      = response.read || ""
          response.finish

          assert_equal 202, response.status
          data = JSON.parse(raw)
          assert_equal "completed", data["status"],
            "terminal header must complete the conversation"
          assert_equal FIXTURE_EVENT_COUNT, data["events"],
            "fixture must produce #{FIXTURE_EVENT_COUNT} normalized events"

          # ── Phase 2: Assert incremental DB persistence ─────────────────────

          conv = Space::Server::App["repos.conversations_repo"].by_pk(data["id"])
          assert_equal :completed, conv.status, "conversation must be completed after terminal ingest"

          msgs = messages_repo.for_conversation(conv.id)
          assert_equal 4, msgs.size, "pi fixture produces 4 DB messages"
          assert_equal [0, 1, 2, 3], msgs.map(&:position), "positions must be sequential"

          # pi order: user prompt, assistant turn (tool_use), tool_result user,
          # second assistant turn.
          assert_equal "user",      msgs[0].role, "position 0 must be the user prompt"
          assert_equal "assistant", msgs[1].role, "position 1 must be the assistant (tool_use) turn"
          assert_equal "user",      msgs[2].role, "position 2 must be the tool_result user message"
          assert_equal "assistant", msgs[3].role, "position 3 must be the second assistant (text)"

          # Block type coverage — every type must round-trip through JSONB
          assert msgs[0].content.any? { |b| b["type"] == "text" },
            "user msg at pos 0 must have text block"
          assert msgs[1].content.any? { |b| b["type"] == "tool_use" },
            "assistant msg at pos 1 must have tool_use block"
          assert msgs[2].content.any? { |b| b["type"] == "tool_result" },
            "user msg at pos 2 must have tool_result block"
          assert msgs[3].content.any? { |b| b["type"] == "text" },
            "assistant msg at pos 3 must have text block"

          # Publish so the anonymous stream GET below passes visibility.
          Space::Server::App["repos.conversations_repo"].update(conv.id, published: true)

          # ── Phase 3: Simulate Redis TTL expiry ────────────────────────────

          Sync { @redis.call("DEL", Space::Server::Conversations::StreamKey.for(conv.id)) }

          # ── Phase 4: GET stream — must replay from DB via db_replay ────────
          #
          # AC-P3 proof: if stream.rb's db_replay cutover were reverted to a
          # no-op, the body proc enters the queue loop (queue.pop timeout=15s),
          # never emits conversation_complete, the 8-second timeout fires, and
          # assert_match below fails.

          env = Rack::MockRequest.env_for(
            "/conversations/#{conv.id}/stream",
            "REQUEST_METHOD" => "GET"
          )
          _, _, body_proc = Space::Server::App.call(env)

          chunks = []
          mock_stream = Object.new.tap do |s|
            s.define_singleton_method(:<<) { |d| chunks << d; s }
            s.define_singleton_method(:close) { |_e = nil| }
          end

          begin
            task.with_timeout(8) do
              body_proc.call(mock_stream)
            end
          rescue Async::TimeoutError
            # db_replay missing → stream loops on heartbeat; timeout = test fail below
          ensure
            Space::Server::Conversations::StreamFanout.stop(conv.id)
          end

          sse = chunks.join

          assert_match "conversation_complete", sse,
            "SSE replay must terminate with conversation_complete " \
            "(AC-P3: reverting the db_replay cutover makes this fail)"
          assert_match "Let me check the existing test patterns.", sse,
            "SSE replay must include assistant text content"
          assert_match "tool_use", sse,
            "SSE replay must include tool_use block events"
          assert_match "tool_result", sse,
            "SSE replay must include tool_result events"
          assert_match "Done. I added a smoke test", sse,
            "SSE replay must include second assistant text content"

          # I12: db_replay emits no id: lines — a fabricated id (e.g. the old
          # "0-1", "0-2", ...) would alias a real Redis stream position, and a
          # client that adopted it as Last-Event-ID would later reconnect with
          # `XRANGE ((0-N` against the real stream and replay it in full (see
          # app/actions/conversations/stream.rb#sse_format). The Redis key was
          # deleted above, so this whole response is pure db_replay: no id:
          # lines at all.
          refute_match(/^id:/, sse, "db_replay must not emit id: lines")
        end
      ensure
        client&.close rescue nil
        server_task.stop
      end
    end
  end
end