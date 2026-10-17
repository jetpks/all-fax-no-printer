# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Show < Space::Server::Action
          CANONICAL_SECTIONS = [
            "Grounds", "Specification", "Acceptance Criteria",
            "Builder Prompt", "Builder Report", "Verdict"
          ].freeze

          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.artifacts_repo",
            "repos.conversations_repo"
          ]

          def handle(req, res)
            id    = req.params[:id].to_i
            space = spaces_repo.by_pk(id)
            halt_not_found(res) unless space

            user = current_user(req)
            unless space.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            iterations = iterations_repo.for_space(space.id)
            artifacts  = artifacts_repo.for_space(space.id)
            conversations = conversations_repo.for_space(space.id)

            iter_artifacts = artifacts.group_by(&:iteration_id)

            iterations_props = iterations.map do |iter|
              {
                id:                     iter.id,
                ordinal:                iter.ordinal,
                name:                   iter.name,
                freeze_sha:             iter.freeze_sha,
                verdict:                iter.verdict,
                created_at:             iter.created_at.iso8601(6),
                occurred_at:            iter.occurred_at&.iso8601(6),
                occurred_at_utc_offset: iter.occurred_at_utc_offset,
                decisions:              decisions_for(iter, iter_artifacts),
                artifacts:              Array(iter_artifacts[iter.id]).map { |a| artifact_props(a) }
              }
            end

            other_artifacts = artifacts.select { |a| a.iteration_id.nil? }
                                       .map { |a| artifact_props(a) }

            render_inertia(req, res, "Spaces/Show", props: {
              space: {
                id:             space.id,
                slug:           space.slug,
                title:          space.title,
                status:         space.status.to_s,
                repos:          Array(space.repos),
                git_utc_offset: space.git_utc_offset
              },
              iterations:      iterations_props,
              conversations:   conversations.map { |c| conversation_props(c) },
              other_artifacts: other_artifacts
            })
          end

          private

          def decisions_for(iter, iter_artifacts)
            iter_art = Array(iter_artifacts[iter.id]).find { |a| a.kind == "iteration" }
            return [] unless iter_art

            sections = Space::Server::SectionParser.split_canonical(iter_art.raw, CANONICAL_SECTIONS)
            CANONICAL_SECTIONS.filter_map do |name|
              next unless sections.key?(name)
              { name: name, body: sections[name] }
            end
          end

          def artifact_props(a)
            { id: a.id, kind: a.kind, path: a.path, title: a.title }
          end

          def conversation_props(c)
            { id: c.id, title: c.title, agent_role: c.agent_role, agent_name: c.agent_name,
              status: c.status, model: c.model, updated_at: c.updated_at&.utc&.iso8601(6) }
          end
        end
      end
    end
  end
end
