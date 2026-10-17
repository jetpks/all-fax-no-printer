# frozen_string_literal: true

require "async"
require "async/condition"
require "async/queue"
require "async/redis"
require_relative "../conversations/stream_key"

module Space
  module Server
    module Spaces
      # Space-level multiplexer over the conversations' Redis display streams —
      # the analog of Conversations::StreamFanout, but one shared live feed per
      # space: every new entry on any of the space's conversation streams is
      # delivered to every subscriber. The mux owns the XREAD loop; subscribers
      # get raw [conversation_id, entry_id, fields, meta] tuples and do their own
      # SSE formatting (backlog replay is the action's XRANGE job, never here).
      class StreamMux
        HEARTBEAT_SECONDS = 15
        RESCAN_SECONDS = 10

        @registry = {}

        def self.for(space_id, redis, conversations_repo)
          @registry[space_id] ||= new(space_id, redis, conversations_repo)
        end

        def self.stop(space_id)
          @registry.delete(space_id)&.stop
        end

        def initialize(space_id, redis, conversations_repo)
          @space_id = space_id
          @redis = redis
          @conversations_repo = conversations_repo
          @subscribers = []
          @task = nil
          @gate = nil
          @gate_open = false
        end

        # Subscribe FIRST (the conversations/stream.rb discipline): blocks until
        # the mux has parked its first XREAD — so a subscriber's subsequent
        # backlog XRANGE cannot race an entry into the gap between its XRANGE and
        # the mux's stream read. Returns the subscriber queue.
        def subscribe
          queue = Async::Queue.new
          @subscribers << queue
          start
          @gate.wait unless @gate_open
          queue
        end

        def unsubscribe(queue)
          @subscribers.delete(queue)
          self.class.stop(@space_id) if @subscribers.empty?
        end

        def stop
          @task&.stop
          @task = nil
          @gate&.signal
          @gate_open = true
        end

        private

        def start
          return if @task&.alive?
          @gate = Async::Condition.new
          @gate_open = false
          @task = Async do
            # Same connection-poisoning discipline as
            # Conversations::StreamFanout (lib/space/server/conversations/
            # stream_fanout.rb): the XREAD here parks a connection with Redis for
            # up to BLOCK ms; riding the shared, pooled `@redis` for that would be
            # a defect — stopping this loop mid-block (a client disconnect)
            # unwinds through async-pool's `acquire { }`, which releases the
            # connection back into the shared pool looking healthy, but Redis
            # still owes it a response for the abandoned block, and the next
            # acquirer queues forever behind a block that never returns. A
            # dedicated client — created for this loop, closed (never released to
            # a pool) on every exit — has nothing to share and nothing to poison.
            dedicated = Async::Redis::Client.new(@redis.endpoint, protocol: @redis.protocol)
            begin
              @conversations = {}
              @last_rescan = nil
              rescan(dedicated)
              # The adoption cursor snapshot is now authoritative: every entry ≤
              # a conversation's cursor is pre-adoption backlog (the subscriber's
              # own XRANGE, issued after this gate opens, covers it) and every
              # entry above it comes through the live tail. From here the action's
              # subscribe→xrange ordering is genuinely race-free.
              @gate_open = true
              @gate&.signal
              loop do
                if @conversations.empty?
                  sleep(RESCAN_SECONDS)
                  rescan(dedicated)
                  next
                end

                keys    = @conversations.values.map { |c| c[:key] }
                cursors = @conversations.values.map { |c| c[:cursor] }
                results = dedicated.xread("BLOCK", (HEARTBEAT_SECONDS * 1000).to_i.to_s,
                                          "STREAMS", *keys, *cursors)
                deliver(results)
                rescan(dedicated) if Time.now - @last_rescan >= RESCAN_SECONDS
              end
            ensure
              dedicated.close
            end
          end
        end

        # Re-query the space's conversations: adopt new ones, refresh the meta
        # snapshot on every adopted conversation, and drop ones the repo no
        # longer returns.
        #
        # A new conversation is adopted with a CONCRETE cursor: the id of its
        # stream's current last entry (XREVRANGE … COUNT 1), or "0" when the
        # stream is empty. This is exactly what "$" would resolve to at the next
        # XREAD — but concrete ids must never be replaced across XREAD calls:
        # re-issuing XREAD with a literal "$" re-resolves to the CURRENT last id,
        # silently skipping anything that arrived between two calls. Pre-adoption
        # entries stay undelivered by design — the backlog is the action's XRANGE
        # job, never the mux's.
        def rescan(dedicated)
          @last_rescan = Time.now
          rows = @conversations_repo.for_space(@space_id)

          metas = {}
          rows.each do |row|
            metas[row.id] = { agent_role: row.agent_role, agent_name: row.agent_name }
            next if @conversations.key?(row.id)
            @conversations[row.id] = {
              id:     row.id,
              key:    Space::Server::Conversations::StreamKey.for(row.id),
              cursor: last_stream_entry_id(dedicated, Space::Server::Conversations::StreamKey.for(row.id))
            }
          end

          @conversations.each do |conversation_id, conversation|
            conversation[:meta] = metas[conversation_id]
          end
          @conversations.delete_if { |conversation_id, _| !metas.key?(conversation_id) }
        end

        # The id of the stream's newest entry, or "0" for an empty (or absent)
        # stream — any future entry sorts above it.
        def last_stream_entry_id(dedicated, key)
          newest = dedicated.xrevrange(key, "+", "-", "COUNT", "1")
          newest&.first&.first || "0"
        end

        # XREAD reply: nil (BLOCK timeout) or a mapping of key → [[entry_id,
        # fields], …] (a Hash or an Array of [key, entries] pairs — both iterate
        # as pairs). Entries for a conversation dropped mid-flight are ignored.
        def deliver(results)
          results&.each do |(key, entries)|
            conversation = @conversations.values.find { |c| c[:key] == key }
            next unless conversation

            entries.each do |entry_id, fields|
              conversation[:cursor] = entry_id
              @subscribers.each { |q| q << [conversation[:id], entry_id, fields, conversation[:meta]] }
            end
          end
        end
      end
    end
  end
end
