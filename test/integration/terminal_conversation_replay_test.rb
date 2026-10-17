# frozen_string_literal: true

# Integration tests for the terminal-conversation cutover boundary (AC-4).
#
# Verifies that GET /conversations/:id/stream ALWAYS terminates with
# conversation_complete for any terminal conversation (completed or failed) —
# never hanging in the live-tail loop.
#
# Two decisive fail-on-base cases:
#   (i)  FAILED conversation (status 3) with persisted messages, Redis DEL'd —
#        replays persisted messages + conversation_complete, never hangs.
#   (ii) COMPLETED conversation (status 2) with zero messages, Redis DEL'd —
#        emits the terminal conversation_complete and closes, never hangs.
#
# AC-4 proof: reverting the stream.rb cutover change causes both cases to enter
# the live-tail loop (queue.pop timeout=15s), never emit conversation_complete
# within the 8-second task timeout, and fail on the assert_match below.

require_relative "../test_helper"
require "rack/mock"
require "async"
require "space/server/conversations/stream_fanout"
require "space/server/conversations/stream_key"

Space::Server::App.start(:redis)

class TerminalConversationReplayTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:messages, :conversations, :users].each { |t| conn[t].delete }
    @user = Factory[:user]
  end

  # Stream /conversations/:id/stream via Rack mock, with an 8-second bounded timeout.
  # Returns the concatenated SSE body (or partial if timeout fires).
  def stream_sse(conversation)
    env = Rack::MockRequest.env_for(
      "/conversations/#{conversation.id}/stream",
      "REQUEST_METHOD" => "GET"
    )
    _, _, body_proc = Space::Server::App.call(env)

    chunks = []
    mock_stream = Object.new.tap do |s|
      s.define_singleton_method(:<<) { |d| chunks << d; s }
      s.define_singleton_method(:close) { |_e = nil| }
    end

    Sync do |task|
      begin
        task.with_timeout(8) do
          body_proc.call(mock_stream)
        end
      rescue Async::TimeoutError
        # live-tail loop hung → SSE will lack conversation_complete → assert_match below fails
      ensure
        Space::Server::Conversations::StreamFanout.stop(conversation.id)
      end
    end

    chunks.join
  end

  # (i) FAILED conversation with persisted messages, Redis stream DEL'd.
  # Must replay persisted message(s) + conversation_complete and terminate.
  def test_failed_conversation_with_messages_replays_and_terminates
    conv = Factory[:conversation, user_id: @user.id, status: 3, published: true]
    Factory[:message,
      conversation_id: conv.id,
      role: "assistant",
      content: [{ "type" => "text", "text" => "terminal-conversation-replay-fixture" }],
      position: 0
    ]

    Sync { Space::Server::App["redis"].call("DEL", Space::Server::Conversations::StreamKey.for(conv.id)) }

    sse = stream_sse(conv)

    assert_match "conversation_complete", sse,
      "FAILED conversation with messages must replay and terminate with conversation_complete " \
      "(AC-4: reverting stream.rb cutover makes this hang and fail)"
    assert_match "terminal-conversation-replay-fixture", sse,
      "FAILED conversation replay must include persisted message content"
  end

  # (ii) COMPLETED conversation with zero messages, Redis stream DEL'd.
  # Must emit the terminal conversation_complete frame and close.
  def test_completed_conversation_without_messages_emits_terminal_and_closes
    conv = Factory[:conversation, user_id: @user.id, status: 2, published: true, turns_count: 0]

    Sync { Space::Server::App["redis"].call("DEL", Space::Server::Conversations::StreamKey.for(conv.id)) }

    sse = stream_sse(conv)

    assert_match "conversation_complete", sse,
      "COMPLETED conversation with zero messages must emit conversation_complete and close " \
      "(AC-4: reverting stream.rb cutover makes this hang and fail)"
  end

  # COMPLETED conversation whose persisted messages include a thinking block.
  # db_replay must emit it as a thinking block, not silently drop it.
  def test_completed_conversation_replays_thinking_blocks
    conv = Factory[:conversation, user_id: @user.id, status: 2, published: true]
    Factory[:message,
      conversation_id: conv.id,
      role: "assistant",
      content: [{ "type" => "thinking", "thinking" => "replay-thinking-fixture" }],
      position: 0
    ]
    Factory[:message,
      conversation_id: conv.id,
      role: "assistant",
      content: [{ "type" => "text", "text" => "final answer" }],
      position: 1
    ]

    Sync { Space::Server::App["redis"].call("DEL", Space::Server::Conversations::StreamKey.for(conv.id)) }

    sse = stream_sse(conv)

    assert_match "conversation_complete", sse
    assert_match '"block_type":"thinking"', sse,
      "db_replay must emit thinking blocks as thinking"
    assert_match "replay-thinking-fixture", sse
  end
end
