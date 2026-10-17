# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        # Upward history pagination for the live log: GET
        # /conversations/:id/stream/history?before=<entry_id>&limit=N returns
        # the at-most-N messages strictly BEFORE the given stream entry
        # (chronological, whole message boundaries — the same StreamWindow
        # windowing as the stream's ?tail), as JSON:
        # {"events": [{"id": ..., "data": {...}}, ...], "more": bool}. The
        # client feeds each event through its live-log reducer exactly like an
        # SSE frame. No DB fallback: when the Redis display stream has expired
        # there is no history to page — the rendered conversation view owns
        # full history.
        class StreamHistory < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo", "redis"]

          # The default page when the client asks no explicit limit.
          DEFAULT_LIMIT = 100

          def handle(req, res)
            conversation = conversations_repo.with_messages(req.params[:id].to_i)
            halt_not_found(res) unless conversation

            user = authenticated_user(req)

            unless conversation.visible_to?(user)
              res.content_type = JSON_CONTENT_TYPE
              if user
                halt 403, JSON.generate(error: "Not authorized.")
              else
                halt 401, JSON.generate(error: "Sign in required.")
              end
            end

            entries = redis.xrange(
              Space::Server::Conversations::StreamKey.for(conversation.id),
              "-",
              StreamWindow.bound(req.params[:before], "+")
            ) || []
            limit = StreamWindow.parse_limit(req.params[:limit]) || DEFAULT_LIMIT
            start = StreamWindow.window_start(entries, limit)

            render_json(res, {
              events: (entries[start..] || []).map { |entry_id, fields| { id: entry_id, data: parsed_event(fields) } },
              more:   start.positive?
            })
          end

          private

          # The entry's data field parsed as JSON; anything unparseable or
          # non-object degrades to the entry's bare type — events are never
          # dropped (the stream action's contract).
          def parsed_event(fields)
            idx = fields.index("data")
            data = idx ? JSON.parse(fields[idx + 1].to_s) : nil
            data.is_a?(Hash) ? data : { "type" => field(fields, "type") }
          rescue JSON::ParserError
            { "type" => field(fields, "type") }
          end

          # Flat Redis fields ([name, value, …]) — the first occurrence of name.
          def field(fields, name)
            idx = fields.index(name)
            idx ? fields[idx + 1] : nil
          end
        end
      end
    end
  end
end
