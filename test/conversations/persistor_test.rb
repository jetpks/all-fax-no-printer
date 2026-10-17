# frozen_string_literal: true

require_relative "../test_helper"
require "space/server/conversations/persistor"

class PersistorTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:messages, :conversations, :users].each { |t| conn[t].delete }
    @user               = Factory[:user]
    @conversations_repo = Space::Server::App["repos.conversations_repo"]
    @messages_repo      = Space::Server::App["repos.messages_repo"]
    @persistor          = Space::Server::Conversations::Persistor.new(@conversations_repo, @messages_repo)
  end

  # Conversation creation (find-or-create + metadata) is the Ingest mouth's
  # job; setup only binds to the existing row.
  def test_setup_binds_to_the_conversation_and_returns_it
    @conversation = Factory[:conversation, user_id: @user.id]
    conv = @persistor.setup(@conversation)
    assert_equal @conversation.id, conv.id
    assert_equal @conversation.id, @persistor.conversation_id
  end

  def test_setup_continues_positions_from_existing_message_count
    @conversation = Factory[:conversation, user_id: @user.id, turns_count: 1]
    @persistor.setup(@conversation)
    Factory[:message, conversation_id: @conversation.id, role: "user",
            content: [{ "type" => "text", "text" => "earlier" }], position: 0]

    [
      { type: :message_start,   role: "user" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "appended chunk" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@conversation.id)
    assert_equal 2, msgs.length
    assert_equal 1, msgs.last.position, "append-chunk positions must continue past existing messages"
  end

  # ── metadata materialization (I08 mouth contract) ─────────────────────

  def test_first_user_message_titles_the_conversation_le80
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    long = "u" * 200
    [
      { type: :message_start,   role: "user" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: long },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete }
    ].each { |e| @persistor.process(e) }

    conv = @conversations_repo.by_pk(@conversation.id)
    assert_equal "u" * 80, conv.title, "title must be the leading user text truncated to 80"
    assert_equal 1,        conv.turns_count
  end

  def test_title_is_set_once_never_overwritten
    @conversation = Factory[:conversation, user_id: @user.id, title: "first title"]
    @persistor.setup(@conversation)

    [
      { type: :message_start,   role: "user" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "second prompt" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete }
    ].each { |e| @persistor.process(e) }

    assert_equal "first title", @conversations_repo.by_pk(@conversation.id).title
  end

  def test_first_assistant_model_materializes_model_column
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    [
      { type: :message_start,   role: "assistant", model: "minimax/minimax-m3" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "reply" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete, stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    assert_equal "minimax/minimax-m3", @conversations_repo.by_pk(@conversation.id).model
    assert_equal "minimax/minimax-m3", @persistor.first_model
  end

  def test_setup_sets_conversation_id_reader
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)
    refute_nil @persistor.conversation_id
  end

  def test_message_complete_persists_text_message
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    [
      { type: :message_start,   role: "assistant", model: "test-model" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "Hello, " },
      { type: :text_delta,      block_id: "0", text: "world!" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 1, msgs.length
    msg = msgs.first
    assert_equal "assistant", msg.role
    assert_equal 0, msg.position
    assert_equal [{ "type" => "text", "text" => "Hello, world!" }], msg.blocks
  end

  def test_tool_use_block_parsed_from_json_deltas
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    [
      { type: :message_start,    role: "assistant", model: nil },
      { type: :block_open,       block_id: "0", index: 0, block_type: :tool_use, name: "Bash", tool_use_id: "tu_1" },
      { type: :tool_args_delta,  block_id: "0", partial_json: '{"command":' },
      { type: :tool_args_delta,  block_id: "0", partial_json: '"ls"}' },
      { type: :block_close,      block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use }
    ].each { |e| @persistor.process(e) }

    msg = @messages_repo.for_conversation(@persistor.conversation_id).first
    block = msg.blocks.first
    assert_equal "tool_use",          block["type"]
    assert_equal "Bash",              block["name"]
    assert_equal({ "command" => "ls" }, block["input"])
  end

  def test_tool_result_event_writes_user_message
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "output text", is_error: false)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 1, msgs.length
    assert_equal "user", msgs.first.role
    block = msgs.first.blocks.first
    assert_equal "tool_result", block["type"]
    assert_equal "tu_1",        block["tool_use_id"]
    assert_equal "output text", block["content"]
  end

  def test_positions_increment_across_messages
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    # First message: assistant text
    [
      { type: :message_start,   role: "assistant", model: nil },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "step" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete }
    ].each { |e| @persistor.process(e) }

    # Second message: tool result
    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "done", is_error: false)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.length
    assert_equal 0, msgs[0].position
    assert_equal 1, msgs[1].position
  end

  def test_tool_result_interleaved_before_message_complete_preserves_order
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    # Real Claude Code fixture order: tool_result fires BEFORE message_complete for the
    # same assistant turn. The assistant message must land at position 0, tool_result at 1.
    [
      { type: :message_start,    role: "assistant", model: "m" },
      { type: :block_open,       block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,       block_id: "0", text: "using tool" },
      { type: :block_close,      block_id: "0" },
      { type: :block_open,       block_id: "1", index: 1, block_type: :tool_use, name: "Bash", tool_use_id: "tu_1" },
      { type: :tool_args_delta,  block_id: "1", partial_json: '{"cmd":"ls"}' },
      { type: :block_close,      block_id: "1" },
      { type: :tool_result,      tool_use_id: "tu_1", content: "file.rb", is_error: false },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.size
    assert_equal "assistant", msgs[0].role, "assistant turn must precede tool_result"
    assert_equal "user",      msgs[1].role
    assert_equal 0, msgs[0].position
    assert_equal 1, msgs[1].position
    assert msgs[0].content.any? { |b| b["type"] == "tool_use" }
    assert msgs[1].content.any? { |b| b["type"] == "tool_result" }
  end

  def test_session_init_and_conversation_complete_events_are_ignored
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    @persistor.process(type: :session_init, session_id: "s1", model: "m", cwd: "/", tools: [])
    @persistor.process(type: :conversation_complete, stop_reason: :end_turn, duration_ms: 100)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 0, msgs.length
  end

  # ── NUL scrubbing (AC4) ───────────────────────────────────────────────────────

  def test_streamed_text_is_scrubbed_of_nul_bytes
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    [
      { type: :message_start,   role: "assistant", model: "test-model" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "Hello, \0wor" },
      { type: :text_delta,      block_id: "0", text: "ld!" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msg = @messages_repo.for_conversation(@persistor.conversation_id).first
    assert_equal [{ "type" => "text", "text" => "Hello, world!" }], msg.blocks
  end

  def test_tool_result_content_is_scrubbed_of_nul_bytes
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "out\0put text", is_error: false)

    block = @messages_repo.for_conversation(@persistor.conversation_id).first.blocks.first
    assert_equal "output text", block["content"]
  end

  def test_full_sequence_produces_correct_db_state
    @conversation = Factory[:conversation, user_id: @user.id]
    @persistor.setup(@conversation)

    [
      { type: :session_init,         session_id: "s1", model: "test", cwd: "/", tools: [] },
      { type: :message_start,    role: "assistant", model: "test" },
      { type: :block_open,       block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,       block_id: "0", text: "Checking…" },
      { type: :block_close,      block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use },
      { type: :tool_result,      tool_use_id: "tu_1", content: "result", is_error: false },
      { type: :conversation_complete,     stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.length
    assert_equal "assistant", msgs[0].role
    assert_equal "user",      msgs[1].role
    assert_equal 0,           msgs[0].position
    assert_equal 1,           msgs[1].position
  end
end
