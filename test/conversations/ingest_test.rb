# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "space/server/conversations/ingest"
require "space/server/conversations/persistor"
require "space/server/conversations/stream_key"

class ConversationsIngestTest < Minitest::Test
  FIXTURE = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_streaming_session.jsonl"))
  MINIMAL_JSONL = "{\"type\":\"session\",\"version\":3,\"id\":\"minimal\",\"cwd\":\"/test\"}\n"

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end

  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:messages, :conversations, :users].each { |t| conn[t].delete }
    @user              = Factory[:user]
    @conversations_repo = Space::Server::App["repos.conversations_repo"]
    @messages_repo      = Space::Server::App["repos.messages_repo"]
  end

  def with_redis
    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      begin
        yield client
      ensure
        client.close
      end
    end
  end

  def ingest(redis, input, persistor: nil, **opts)
    Space::Server::Conversations::Ingest.new(redis, conversations_repo: @conversations_repo, persistor: persistor)
      .call(@user, StringIO.new(input), **opts)
  end

  def full_ingest(redis, input, **opts)
    persistor = Space::Server::Conversations::Persistor.new(@conversations_repo, @messages_repo)
    ingest(redis, input, persistor: persistor, **opts).merge(persistor: persistor)
  end

  # --- identity / find-or-create ------------------------------------------------

  def test_session_record_creates_conversation_keyed_by_session_id
    with_redis do |redis|
      result = full_ingest(redis, MINIMAL_JSONL)
      conv = @conversations_repo.by_pk(result[:persistor].conversation_id)
      assert_equal "minimal", conv.session_id
      assert_equal @user.id,  conv.user_id
      assert_equal "pi",      conv.source
      assert_equal "/test",   conv.original_cwd
      assert_equal "3",       conv.agent_version
      assert_equal :live,     conv.status
    end
  end

  def test_session_record_reappearing_resolves_to_same_conversation
    with_redis do |redis|
      first  = full_ingest(redis, MINIMAL_JSONL)
      second = full_ingest(redis, MINIMAL_JSONL)
      assert_equal first[:persistor].conversation_id, second[:persistor].conversation_id
      assert_equal 1, @conversations_repo.by_user(@user.id).length, "no duplicate conversation"
    end
  end

  def test_find_by_session_id_find_or_create_is_owner_scoped
    with_redis do |redis|
      full_ingest(redis, MINIMAL_JSONL)
      other = Factory[:user]
      Space::Server::Conversations::Ingest.new(redis, conversations_repo: @conversations_repo)
        .call(other, StringIO.new(MINIMAL_JSONL))
      mine   = @conversations_repo.by_user(@user.id).first
      theirs = @conversations_repo.by_user(other.id).first
      refute_equal mine.id, theirs.id, "another user's same session id gets its own conversation"
      assert_equal "minimal", theirs.session_id
    end
  end

  # --- metadata materialization -------------------------------------------------

  def test_optional_metadata_headers_materialize_at_creation
    body = "{\"type\":\"session\",\"version\":7,\"id\":\"meta-1\",\"cwd\":\"/w\"}\n"
    with_redis do |redis|
      result = full_ingest(redis, body,
        space_id: 12, parent_session_id: "parent-1", agent_role: "builder", agent_name: "Mouth")
      conv = @conversations_repo.by_pk(result[:persistor].conversation_id)
      assert_equal 12,          conv.space_id
      assert_equal "parent-1",  conv.parent_session_id
      assert_equal "builder",   conv.agent_role
      assert_equal "Mouth",     conv.agent_name
      assert_equal "7",         conv.agent_version
    end
  end

  def test_re_processing_session_record_is_a_metadata_noop
    body = "{\"type\":\"session\",\"version\":7,\"id\":\"meta-2\",\"cwd\":\"/w\"}\n"
    with_redis do |redis|
      full_ingest(redis, body, parent_session_id: "p1", agent_role: "builder")
      # Re-send with DIFFERENT headers — must not overwrite creation metadata.
      full_ingest(redis, body, parent_session_id: "p2", agent_role: "judge")
      conv = @conversations_repo.by_user(@user.id).find { |c| c.session_id == "meta-2" }
      assert_equal "p1",      conv.parent_session_id
      assert_equal "builder", conv.agent_role
    end
  end

  # --- per-record idempotency (applied_record_ids) --------------------------------

  def test_whole_file_resend_lands_zero_duplicates_and_zero_new_events
    with_redis do |redis|
      first  = full_ingest(redis, FIXTURE)
      key    = Space::Server::Conversations::StreamKey.for(first[:persistor].conversation_id)
      xlen_1 = redis_xlen(redis, key)

      second = full_ingest(redis, FIXTURE)
      assert_equal first[:persistor].conversation_id, second[:persistor].conversation_id
      assert_equal 0, second[:events], "re-sent records must be skipped entirely"
      assert_equal xlen_1, redis_xlen(redis, key), "no re-fanned-out frames"

      msgs = @messages_repo.for_conversation(first[:persistor].conversation_id)
      assert_equal 4, msgs.length, "no duplicate messages"
    end
  end

  def test_applied_record_ids_carry_session_and_line_identities
    with_redis do |redis|
      result = full_ingest(redis, MINIMAL_JSONL)
      conv = @conversations_repo.by_pk(result[:persistor].conversation_id)
      assert_includes conv.applied_record_ids, "minimal", "the session record's id is the first applied identity"
    end
  end

  def test_chunked_append_applies_only_new_records
    with_redis do |redis|
      result = full_ingest(redis, MINIMAL_JSONL)
      conv_id = result[:persistor].conversation_id

      appended = MINIMAL_JSONL + "{\"type\":\"message_end\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"next chunk\"}]}}\n"
      second = full_ingest(redis, appended)
      assert_equal conv_id, second[:persistor].conversation_id
      assert_equal 5, second[:events], "only the new record's events applied"
      msgs = @messages_repo.for_conversation(conv_id)
      assert_equal 1, msgs.length
    end
  end

  # --- terminal semantics ---------------------------------------------------------

  def test_terminal_flag_completes_and_fans_out_terminal_frame
    with_redis do |redis|
      result = full_ingest(redis, MINIMAL_JSONL, terminal: true)
      conv = @conversations_repo.by_pk(result[:persistor].conversation_id)
      assert_equal :completed, conv.status

      key = Space::Server::Conversations::StreamKey.for(conv.id)
      entries = redis.xrange(key, "-", "+")
      assert_equal "conversation_complete", entries.last[1][1], "terminal SSE event XADDed"
      # session_init + terminal frame — no synthetic terminal without the flag
      assert_equal result[:events] + 1, entries.length
    end
  end

  def test_non_terminal_post_stays_live_without_terminal_frame
    with_redis do |redis|
      result = full_ingest(redis, MINIMAL_JSONL)
      conv = @conversations_repo.by_pk(result[:persistor].conversation_id)
      assert_equal :live, conv.status
      entries = redis.xrange(Space::Server::Conversations::StreamKey.for(conv.id), "-", "+")
      assert_equal result[:events], entries.length, "no terminal frame when the POST is not terminal"
    end
  end

  def test_reterminating_completed_conversation_does_not_refanout
    with_redis do |redis|
      key = nil
      full_ingest(redis, MINIMAL_JSONL, terminal: true).tap do |r|
        key = Space::Server::Conversations::StreamKey.for(r[:persistor].conversation_id)
      end
      count = redis_xlen(redis, key)
      full_ingest(redis, MINIMAL_JSONL, terminal: true)
      assert_equal count, redis_xlen(redis, key), "terminal frame is one-shot per conversation"
    end
  end

  # --- visible failure (I05 rule) ---------------------------------------------------

  def test_empty_input_fails_with_zero_events
    with_redis do |redis|
      result = ingest(redis, "")
      assert_equal 0, result[:events]
      assert_equal :failed, result[:status]
      assert result[:error], "zero-event ingest must carry an explanatory error"
    end
  end

  def test_non_session_first_record_fails_visibly
    with_redis do |redis|
      result = ingest(redis, "{\"type\":\"message_end\",\"message\":{}}\n")
      assert_equal :failed, result[:status]
      assert result[:error].include?("session record"), "error passthrough names the contract"
    end
  end

  # A re-sent session record plus an unrecognized record is a no-op success,
  # not a failure — the stream IS recognized pi (the session record engaged the
  # parser); only never-recognized bodies fail visibly.
  def test_resend_plus_unrecognized_record_is_a_noop_success
    with_redis do |redis|
      full_ingest(redis, MINIMAL_JSONL)
      result = full_ingest(redis, "{\"type\":\"session\",\"version\":3,\"id\":\"minimal\",\"cwd\":\"/test\"}\n{\"type\":\"mystery\"}\n")
      assert_equal 0, result[:events]
      assert_equal :live, result[:status]
      refute result[:error]
    end
  end

  def test_failure_fans_out_the_terminal_frame
    with_redis do |redis|
      calls = 0
      io = Object.new
      io.define_singleton_method(:gets) do
        calls += 1
        raise "simulated read error" if calls > 1
        "{\"type\":\"session\",\"version\":3,\"id\":\"io-term\",\"cwd\":\"/t\"}\n"
      end

      result = Space::Server::Conversations::Ingest.new(redis, conversations_repo: @conversations_repo)
        .call(@user, io)
      assert_equal :failed, result[:status]

      conv = @conversations_repo.by_user(@user.id).find { |c| c.session_id == "io-term" }
      entries = redis.xrange(Space::Server::Conversations::StreamKey.for(conv.id), "-", "+")
      assert_equal "conversation_complete", entries.last[1][1], "failure closes live viewers"
    end
  end

  # --- stream mechanics ------------------------------------------------------------

  def test_events_appear_in_stream_with_ttl
    with_redis do |redis|
      result = full_ingest(redis, FIXTURE)
      key = Space::Server::Conversations::StreamKey.for(result[:persistor].conversation_id)
      entries = redis.xrange(key, "-", "+")
      assert_equal result[:events], entries.length
      types = entries.map { |e| e[1][1] }
      assert_includes types, "session_init"
      assert_includes types, "message_start"
      ttl = redis.ttl(key)
      assert ttl > 0, "TTL refreshed per XADD"
    end
  end

  # --- messages persisted incrementally ---------------------------------------------

  def test_ingest_with_persistor_persists_messages_and_metadata
    with_redis do |redis|
      result = full_ingest(redis, FIXTURE)
      conv_id = result[:persistor].conversation_id
      msgs = @messages_repo.for_conversation(conv_id)
      assert_equal 4, msgs.length, "pi fixture produces 4 DB messages"
      assert_equal "user", msgs.first.role

      conv = @conversations_repo.by_pk(conv_id)
      assert_equal "add a smoke test for the importer", conv.title, "title from first user text"
      assert_equal "minimax/minimax-m3", conv.model, "model from first assistant message"
      assert_equal 4, conv.turns_count, "turns_count = messages written"
    end
  end

  def test_ingest_without_persistor_still_streams
    with_redis do |redis|
      result = ingest(redis, MINIMAL_JSONL)
      assert_equal :live, result[:status]
      assert_equal 1, result[:events]
    end
  end

  def test_raising_io_fails_visibly
    with_redis do |redis|
      calls = 0
      io = Object.new
      io.define_singleton_method(:gets) do
        calls += 1
        raise "simulated read error" if calls > 1
        "{\"type\":\"session\",\"version\":3,\"id\":\"io-err\",\"cwd\":\"/t\"}\n"
      end

      result = Space::Server::Conversations::Ingest.new(redis, conversations_repo: @conversations_repo)
        .call(@user, io)
      assert_equal :failed, result[:status], "rescue path must return :failed"
      assert_equal "simulated read error", result[:error]
    end
  end

  def redis_xlen(redis, key)
    redis.xrange(key, "-", "+").length
  end
end
