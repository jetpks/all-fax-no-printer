# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        # Upward history pagination for the space live log: GET
        # /spaces/:id/stream/history?before=<sse_id>&limit=N returns the
        # at-most-N messages strictly BEFORE the given envelope id
        # ("<conversation_id>:<ms>-<seq>"), merged across the space's
        # conversations chronologically with the SAME envelope the SSE stream
        # carries (StreamEvents). JSON shape matches the conversation history
        # endpoint: {"events": [{"id": "<conv>:<ms>-<seq>", "data": {...}}, …],
        # "more": bool}.
        class StreamHistory < Space::Server::Action
          include Space::Server::Deps["repos.spaces_repo", "repos.conversations_repo", "redis"]

          # The default page when the client asks no explicit limit.
          DEFAULT_LIMIT = 100

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

            upper = Space::Server::Spaces::StreamEvents.history_bounds(req.params[:before])
            limit = Space::Server::StreamWindow.parse_limit(req.params[:limit]) || DEFAULT_LIMIT
            conversations = conversations_repo.for_space(space.id)
            meta = conversations.to_h { |c| [c.id, { agent_role: c.agent_role, agent_name: c.agent_name }] }

            entries = conversations.flat_map do |c|
              key = Space::Server::Conversations::StreamKey.for(c.id)
              # The bound's own conversation gets the exact exclusive id; other
              # conversations a same-millisecond bound (seq counters aren't
              # comparable across streams — the stream's documented edge).
              end_bound = upper ? (c.id == upper[:conv_id] ? upper[:exact] : upper[:other]) : "+"
              (redis.xrange(key, "-", end_bound) || []).map { |entry| [c.id, entry] }
            end
            # Numeric (ms, seq) sort across conversations — a plain string sort
            # is wrong at seq ≥ 10 (same as the stream's backlog).
            entries.sort_by! { |_, (entry_id, _)| Space::Server::Spaces::StreamEvents.entry_key(entry_id) }

            # window_start wants flat [entry_id, fields] pairs; the merged
            # entries carry [conversation_id, entry] — index-aligned, so the
            # same window start slices either.
            start = Space::Server::StreamWindow.window_start(entries.map { |_, entry| entry }, limit)
            render_json(res, {
              events: (entries[start..] || []).map do |conversation_id, (entry_id, fields)|
                { id: "#{conversation_id}:#{entry_id}", data: Space::Server::Spaces::StreamEvents.merge_event(conversation_id, entry_id, fields, meta[conversation_id]) }
              end,
              more: start.positive?
            })
          end
        end
      end
    end
  end
end
