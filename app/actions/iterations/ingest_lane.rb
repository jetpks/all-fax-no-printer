# frozen_string_literal: true

require_relative "../../contracts/ingest_iteration_lane"

module Space
  module Server
    module Actions
      module Iterations
        # Mouth 2 — the lane-completion emission. Bearer-authed machine mouth;
        # X-Space-Slug scopes everything to the token owner's space.
        class IngestLane < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo", "repos.iterations_repo", "repos.gates_repo",
            "repos.lanes_repo", "repos.gate_results_repo", "repos.verdicts_repo",
            "repos.verdict_rulings_repo"
          ]

          CONTRACT = Contracts::IngestIterationLane.new

          def handle(req, res)
            user = token_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            slug = req.get_header("HTTP_X_SPACE_SLUG").to_s.strip
            halt_unprocessable(res, ["X-Space-Slug header is required."]) if slug.empty?

            result = CONTRACT.call(req.params.to_h)
            halt_unprocessable(res, Space::Server::Iterations::ContractErrors.flatten(result.errors.to_h)) if result.failure?

            ingest = Space::Server::Iterations::Ingest.new(
              spaces_repo: spaces_repo, iterations_repo: iterations_repo, gates_repo: gates_repo,
              lanes_repo: lanes_repo, gate_results_repo: gate_results_repo,
              verdicts_repo: verdicts_repo, verdict_rulings_repo: verdict_rulings_repo
            )
            space = spaces_repo.upsert_by_slug(user.id, slug, title: slug)
            outcome = ingest.lane(space.id, result.to_h)
            halt_unprocessable(res, [outcome[:error]]) if outcome[:error]

            render_json(res, {
              space:     { id: space.id, slug: space.slug },
              iteration: iteration_json(outcome[:iteration]),
              lane:      { id: outcome[:lane].id, name: outcome[:lane].name },
              gate_results_applied: outcome[:gate_results_applied]
            })
          end

          private

          def iteration_json(iteration)
            { id: iteration.id, ordinal: iteration.ordinal, name: iteration.name,
              freeze_sha: iteration.freeze_sha, status: iteration.status }
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
