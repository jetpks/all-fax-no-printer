# frozen_string_literal: true

require "json"
require "digest"
require_relative "stream_key"
require_relative "../normalizer"

module Space
  module Server
    module Conversations
      class Ingest
        MAXLEN = "10000"
        NO_EVENTS_ERROR = "Stream contained no recognizable events."
        NOT_PI_ERROR = "Stream's first record must be a pi session record (\"type\":\"session\")."
        TERMINAL_EVENT_TYPE = "conversation_complete"
        STATUS_TO_INT = { live: 1, completed: 2, failed: 3 }.freeze

        def initialize(redis, conversations_repo:, persistor: nil)
          @redis              = redis
          @conversations_repo = conversations_repo
          @persistor          = persistor
        end

        # Reads pi --mode json JSONL lines from input (rack.input / StringIO / any IO
        # responding to #gets), normalizes each via Space::Server::Normalizer, XADDs
        # each event onto the conversation's Redis stream, and refreshes the TTL per
        # XADD. When a persistor is provided, also persists messages incrementally.
        #
        # The session record ({"type":"session",...}) is the identity source: the
        # first POST of a session must open with it; re-sent session records resolve
        # to the same conversation via find-by-(user, session id) and re-processing
        # them is a metadata no-op. Per-record idempotency: each applied record's
        # identity lands in conversations.applied_record_ids; an already-applied
        # record is skipped ENTIRELY — no message write, no XADD, so a live viewer
        # never sees a re-sent record twice.
        #
        # Returns { events: newly applied count, status: :completed|:live|:failed,
        # error?: "…" }. A stream whose records are all recognized (applied now or
        # already-applied dedup hits) never fails silently: only a body that
        # produces zero recognized events fails visibly (I05 rule).
        def call(user, input, space_id: nil, parent_session_id: nil, agent_role: nil, agent_name: nil, terminal: false)
          parser = nil
          conversation = nil
          # The applied-identity log for this POST. Seeded from the row when the
          # conversation resolves; ROM structs are read-only, so the local list
          # is the working copy (the DB write in record_applied is the truth).
          applied_record_ids = []
          recognized_count = 0
          dedup_hits = 0
          applied_count = 0

          while (line = input.gets)
            line = line.strip
            next if line.empty?

            record = JSON.parse(line) rescue next
            unless parser
              selected = Normalizer.select(record)
              raise NOT_PI_ERROR unless selected
              parser = selected.new
            end

            if record["type"] == "session" && conversation.nil?
              conversation = resolve_conversation(user, record,
                space_id: space_id, parent_session_id: parent_session_id,
                agent_role: agent_role, agent_name: agent_name)
              applied_record_ids.replace(conversation.applied_record_ids)
              @persistor&.setup(conversation)
            end

            identity = record_identity(record, line)
            if applied?(conversation, applied_record_ids, identity)
              dedup_hits += 1
              next
            end

            events = parser.process(record)
            recognized_count += events.size

            events.each do |event|
              xadd(StreamKey.for(conversation.id), event)
              @persistor&.process(event)
              applied_count += 1
            end
            applied_record_ids << identity
            @conversations_repo.update(conversation.id,
              applied_record_ids: applied_record_ids)
          end

          # A no-op re-send (all records already applied) is not a failure: the
          # zero-event rule targets streams that were never recognized at all.
          if recognized_count.zero? && dedup_hits.zero?
            fail_conversation(conversation)
            return { events: 0, status: :failed, error: NO_EVENTS_ERROR }
          end

          final_status = terminal ? :completed : :live
          # Terminal frames precede the status write — the frame guard reads the
          # pre-write status to keep a terminal frame one-shot per conversation.
          if terminal
            emit_terminal_frame(conversation)
            update_status(conversation, :completed)
          elsif applied_count.positive?
            update_status(conversation, :live)
          end
          { events: applied_count, status: final_status }
        rescue => e
          # Failure closes live viewers too: the terminal frame (error passthrough
          # to the 202 body, conversation_complete to the stream) ends the tail.
          fail_conversation(conversation)
          { events: applied_count, status: :failed, error: e.message }
        end

        private

        # Find-or-create by (user_id, session_id) — the session record's "id" is
        # the key. Metadata materializes at creation; an existing conversation
        # only has blanks filled (re-processing is a metadata no-op).
        def resolve_conversation(user, record, space_id:, parent_session_id:, agent_role:, agent_name:)
          existing = @conversations_repo.find_by_session_id(user.id, record["id"])
          return fill_blanks(existing, space_id: space_id, parent_session_id: parent_session_id,
                             agent_role: agent_role, agent_name: agent_name) if existing

          now = Time.now
          @conversations_repo.create(
            user_id:            user.id,
            session_id:         record["id"],
            status:             1, # :live — the mouth's non-terminal posture
            published:          false,
            source:             "pi",
            original_cwd:       record["cwd"],
            agent_version:      record["version"]&.to_s,
            parent_session_id:  parent_session_id,
            agent_role:         agent_role,
            agent_name:         agent_name,
            space_id:           space_id,
            applied_record_ids: [],
            created_at:         now,
            updated_at:         now
          )
        end

        def fill_blanks(conversation, space_id:, parent_session_id:, agent_role:, agent_name:)
          updates = {}
          updates[:space_id]          = space_id          if space_id && conversation.space_id.nil?
          updates[:parent_session_id] = parent_session_id if parent_session_id && conversation.parent_session_id.nil?
          updates[:agent_role]        = agent_role        if agent_role && conversation.agent_role.nil?
          updates[:agent_name]        = agent_name        if agent_name && conversation.agent_name.nil?
          @conversations_repo.update(conversation.id, updates) unless updates.empty?
          conversation
        end

        # A record's identity is its "id" when it carries one; id-less records
        # (pi's message_end / tool_execution_end rows) are content-addressed by
        # the SHA-256 of their raw line — byte-identical re-sents (whole-file
        # re-send, chunk retry, reconnect replay) collide, novel records don't.
        def record_identity(record, line)
          id = record["id"]
          return id.to_s if id && !id.to_s.empty?
          "line:#{Digest::SHA256.hexdigest(line)}"
        end

        def applied?(conversation, applied_record_ids, identity)
          return false unless conversation
          applied_record_ids.include?(identity)
        end

        def update_status(conversation, status)
          return unless conversation
          @conversations_repo.update(conversation.id, status: STATUS_TO_INT.fetch(status), updated_at: Time.now)
        end

        def fail_conversation(conversation)
          return unless conversation
          # Frame before the status write: the frame guard reads the pre-write
          # status to keep the terminal frame one-shot per conversation.
          emit_terminal_frame(conversation)
          update_status(conversation, :failed)
        end

        # Terminal frames XADD exactly once per conversation: a re-terminated
        # (already terminal) conversation must not re-fan-out the event.
        def emit_terminal_frame(conversation)
          return unless conversation
          current = @conversations_repo.by_pk(conversation.id)
          return if current.status == :completed || current.status == :failed

          key = StreamKey.for(conversation.id)
          @redis.xadd(key, "MAXLEN", "~", MAXLEN, "*", "type", TERMINAL_EVENT_TYPE,
            "data", JSON.generate(type: TERMINAL_EVENT_TYPE))
          @redis.expire(key, StreamKey::TTL_SECONDS)
        end

        def xadd(key, event)
          @redis.xadd(key, "MAXLEN", "~", MAXLEN, "*", "type", event[:type].to_s, "data", JSON.generate(event))
          @redis.expire(key, StreamKey::TTL_SECONDS)
        end
      end
    end
  end
end
