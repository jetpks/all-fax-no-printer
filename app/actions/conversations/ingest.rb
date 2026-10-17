# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        # The ingest mouth: a bearer-authed machine endpoint that materializes
        # full-fidelity pi session records onto conversations. The body stays
        # raw pi JSONL (IngestBodyPassthrough keeps rack.input untouched); all
        # session metadata rides the optional headers:
        #   X-Space-Slug         → find-or-create the user's space, link it
        #   X-Parent-Session-Id  → parent linkage (subagent/fork)
        #   X-Agent-Role         → role tag (architect/builder/…; absent = interactive)
        #   X-Agent-Name         → agent display name
        #   X-Session-Complete: true → terminal (status :completed + terminal
        #   SSE event); absent → :live
        class Ingest < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo", "repos.messages_repo", "repos.spaces_repo", "redis"]

          def handle(req, res)
            user = token_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            persistor = Space::Server::Conversations::Persistor.new(conversations_repo, messages_repo)
            ingest = Space::Server::Conversations::Ingest.new(redis, conversations_repo: conversations_repo, persistor: persistor)
            result = ingest.call(user, req.env["rack.input"], **ingest_options(req, user))

            conversation = persistor.conversation_id && conversations_repo.by_pk(persistor.conversation_id)
            json = {
              id:         conversation&.id,
              session_id: conversation&.session_id,
              status:     result[:status],
              events:     result[:events]
            }
            json[:error] = result[:error] if result[:error] # the why, not just the verdict
            render_json(res, json, status: 202)
          end

          private

          def ingest_options(req, user)
            {
              space_id:          space_id_from_slug(req, user),
              parent_session_id: header(req, "HTTP_X_PARENT_SESSION_ID"),
              agent_role:        header(req, "HTTP_X_AGENT_ROLE"),
              agent_name:        header(req, "HTTP_X_AGENT_NAME"),
              terminal:          header(req, "HTTP_X_SESSION_COMPLETE").to_s.casecmp("true").zero?
            }
          end

          # Optional space linkage: the slug find-or-creates the authenticated
          # user's space (title defaults to the slug). Absent → NULL space_id;
          # grouping then falls to the session's working directory.
          def space_id_from_slug(req, user)
            slug = header(req, "HTTP_X_SPACE_SLUG")
            return nil if slug.nil? || slug.strip.empty?

            spaces_repo.upsert_by_slug(user.id, slug.strip, title: slug.strip).id
          end

          def header(req, name)
            req.get_header(name)
          end

          # Bearer machine mouth: exempt from CSRF on bearer presence — a
          # cookie-borne POST without a valid bearer already 401s above, so the
          # exemption carries no state-changing surface.
          def verify_csrf_token?(req, *)
            bearer_request?(req) ? false : super
          end
        end
      end
    end
  end
end
