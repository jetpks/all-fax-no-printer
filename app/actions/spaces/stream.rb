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
        # "<conversation_id>:<entry_id>" for Last-Event-ID resume.
        class Stream < Space::Server::Action
          include Space::Server::Deps["repos.spaces_repo", "repos.conversations_repo", "redis"]

          # Display tag map (frozen): the agent's role abbreviates when known;
          # otherwise a truncated agent name; otherwise the bare conversation id.
          ROLE_ABBREV = {
            "architect-coordinator" => "coord",
            "architect-spec" => "spec",
            "architect-judge" => "judge",
            "architect-builder" => "bld",
            "architect-narrator" => "narr"
          }.freeze

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

            start_bound = resume_bound(req.get_header("HTTP_LAST_EVENT_ID"))
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
                emit_backlog(stream, conversations, start_bound, meta, delivered)

                # Live tail. conversation_complete is an ordinary event here —
                # no break; the stream ends only on client disconnect.
                loop do
                  item = queue.pop(timeout: Space::Server::Spaces::StreamMux::HEARTBEAT_SECONDS)
                  if item.nil?
                    stream << ": ping\n\n"
                    next
                  end

                  conversation_id, entry_id, fields, entry_meta = item
                  next if delivered_before?(delivered[conversation_id], entry_id)

                  delivered[conversation_id] = entry_key(entry_id)
                  stream << sse_event(conversation_id, entry_id, fields, entry_meta || meta[conversation_id])
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
          def emit_backlog(stream, conversations, start_bound, meta, delivered)
            entries = conversations.flat_map do |c|
              key = Space::Server::Conversations::StreamKey.for(c.id)
              (redis.xrange(key, start_bound, "+") || []).map { |entry| [c.id, entry] }
            end
            entries.sort_by! { |_, (entry_id, _)| entry_key(entry_id) }

            entries.each do |conversation_id, (entry_id, fields)|
              next if delivered_before?(delivered[conversation_id], entry_id)

              delivered[conversation_id] = entry_key(entry_id)
              stream << sse_event(conversation_id, entry_id, fields, meta[conversation_id])
            end
          end

          # The envelope-merged SSE frame. `data:` JSON is the entry's event
          # object merged at top level with conversation identity. A data field
          # that fails to parse as a JSON object degrades to {"type": <type>} —
          # never dropped.
          def sse_event(conversation_id, entry_id, fields, entry_meta)
            agent_role = entry_meta&.dig(:agent_role)
            agent_name = entry_meta&.dig(:agent_name)
            event = parsed_event(fields)
            event = { "type" => field(fields, "type") } unless event.is_a?(Hash)
            event = event.merge(
              "conversation_id" => conversation_id,
              "agent_role"      => agent_role,
              "agent_name"      => agent_name,
              "tag"             => tag(conversation_id, agent_role, agent_name)
            )
            "id: #{conversation_id}:#{entry_id}\ndata: #{JSON.generate(event)}\n\n"
          end

          # The entry's data field parsed as JSON, or nil when it isn't JSON.
          def parsed_event(fields)
            JSON.parse(field(fields, "data").to_s)
          rescue JSON::ParserError
            nil
          end

          # Flat Redis fields ([name, value, …]) — the first occurrence of name.
          def field(fields, name)
            idx = fields.index(name)
            idx ? fields[idx + 1] : nil
          end

          def tag(conversation_id, agent_role, agent_name)
            ROLE_ABBREV[agent_role] || agent_name&.to_s&.slice(0, 10) || "conv-#{conversation_id}"
          end

          # Last-Event-ID "<conversation_id>:<ms>-<seq>" or bare "<ms>-<seq>": the
          # entry-id part after the last ":" is the EXCLUSIVE XRANGE lower bound
          # applied to EVERY conversation's stream. Absent/unparseable → "-" (the
          # full backlog). No db_replay fallback — the space stream is a live
          # tail; history lives on conversation pages and in the Redis backlog
          # (TTL 1800s / MAXLEN 10000).
          def resume_bound(last_event_id)
            entry_id = last_event_id.to_s.split(":").last
            return "-" unless entry_id&.match?(/\A\d+-\d+\z/)

            "(#{entry_id}"
          end

          # Delivered cursor is a numeric (ms, seq) tuple; entry ids sort numerically
          # (a string compare is wrong at seq ≥ 10: "-9" vs "-10").
          def delivered_before?(cursor, entry_id)
            return false unless cursor

            (entry_key(entry_id) <=> cursor) <= 0
          end

          # Entry id "ms-seq" as a comparable numeric tuple.
          def entry_key(entry_id)
            parts = entry_id.to_s.split("-")
            [Integer(parts[0] || 0, 10), Integer(parts[1] || 0, 10)]
          rescue ArgumentError, TypeError
            [0, 0]
          end
        end
      end
    end
  end
end
