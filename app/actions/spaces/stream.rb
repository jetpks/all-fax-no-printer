# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        # Live SSE multiplexing a space's conversations' Redis display streams —
        # the phone observation deck feed. Mechanics follow
        # conversations/stream.rb (authz posture, subscribe-then-xrange race
        # discipline, 15s heartbeat), minus db_replay and minus any terminal
        # break: this is a pure live tail, the stream ends only on client
        # disconnect. Every event merges the per-conversation normalized event
        # (the conversations/stream.rb vocabulary) at top level with an envelope
        # of conversation identity keys, and carries SSE id
        # "<conversation_id>:<entry_id>" for Last-Event-ID resume. A fresh connect
        # with `?tail=N` replays only the last N messages (message-boundary
        # windowed, StreamWindow); a Last-Event-ID reconnect replays everything
        # after its cursor.
        class Stream < Space::Server::Action
          include Space::Server::Deps["repos.spaces_repo", "repos.conversations_repo", "redis"]

          # The event-envelope contract lives in Space::Server::Spaces (not in
          # this action's lexical chain); aliased here for the hot loop below.
          StreamEvents = Space::Server::Spaces::StreamEvents
          StreamWindow = Space::Server::StreamWindow

          def handle(req, res)
            space = spaces_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless space

            user = authenticated_user(req)

            unless space.visible_to?(user)
              res.content_type = JSON_CONTENT_TYPE
              if user
                halt 403, JSON.generate(error: "Not authorized.")
              else
                halt 401, JSON.generate(error: "Sign in required.")
              end
            end

            res.status = 200
            res.headers["content-type"] = "text/event-stream"
            res.headers["cache-control"] = "no-cache"
            res.headers["x-accel-buffering"] = "no"

            start_bound = StreamWindow.bound(req.get_header("HTTP_LAST_EVENT_ID"), "-")
            # Fresh connect (no Last-Event-ID): replay only the last `tail`
            # messages; a native reconnect replays everything after its cursor.
            tail = req.get_header("HTTP_LAST_EVENT_ID") ? nil : StreamWindow.parse_limit(req.params[:tail])
            conversations = conversations_repo.for_space(space.id)
            meta = conversations.to_h { |c| [c.id, { agent_role: c.agent_role, agent_name: c.agent_name }] }
            mux = Space::Server::Spaces::StreamMux.for(space.id, redis, conversations_repo)

            body = proc do |stream|
              # Subscribe FIRST, then xrange the backlog: anything the mux queues
              # meanwhile is deduped below against the delivered cursor.
              queue = mux.subscribe
              delivered = {}
              error = nil

              begin
                emit_backlog(stream, conversations, start_bound, meta, delivered, tail)

                # Live tail. conversation_complete is an ordinary event here —
                # no break; the stream ends only on client disconnect.
                loop do
                  item = queue.pop(timeout: Space::Server::Spaces::StreamMux::HEARTBEAT_SECONDS)
                  if item.nil?
                    stream << ": ping\n\n"
                    next
                  end

                  conversation_id, entry_id, fields, entry_meta = item
                  next if StreamEvents.delivered_before?(delivered[conversation_id], entry_id)

                  delivered[conversation_id] = StreamEvents.entry_key(entry_id)
                  stream << StreamEvents.sse_event(conversation_id, entry_id, fields, entry_meta || meta[conversation_id])
                end
              rescue => error
              ensure
                mux.unsubscribe(queue)
                stream.close(error)
              end
            end

            res.instance_variable_set(:@body, body)
          end

          private

          # Backlog across all the space's conversations, emitted chronologically.
          # Redis stream ids are "ms-seq"; the numeric (ms, seq) sort is required —
          # a plain string sort is wrong ("1776700000000-9" > "1776700000000-10").
          # `tail` (messages) windows the merged backlog to its last N messages;
          # the event envelope itself is StreamEvents (shared with the history
          # endpoint).
          def emit_backlog(stream, conversations, start_bound, meta, delivered, tail)
            entries = conversations.flat_map do |c|
              key = Space::Server::Conversations::StreamKey.for(c.id)
              (redis.xrange(key, start_bound, "+") || []).map { |entry| [c.id, entry] }
            end
            entries.sort_by! { |_, (entry_id, _)| StreamEvents.entry_key(entry_id) }

            # window_start wants flat [entry_id, fields] pairs; the merged
            # entries carry [conversation_id, entry] — index-aligned, so the
            # same window start slices either.
            start = StreamWindow.window_start(entries.map { |_, entry| entry }, tail)
            entries[start..].each do |conversation_id, (entry_id, fields)|
              next if StreamEvents.delivered_before?(delivered[conversation_id], entry_id)

              delivered[conversation_id] = StreamEvents.entry_key(entry_id)
              stream << StreamEvents.sse_event(conversation_id, entry_id, fields, meta[conversation_id])
            end
          end
        end
      end
    end
  end
end
