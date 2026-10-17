# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Runs
        class Show < Space::Server::Action
          include Space::Server::Deps["repos.runs_repo"]

          def handle(req, res)
            id = req.params[:id].to_i
            run = runs_repo.for_show(id)
            halt_not_found(res) unless run

            user = current_user(req)

            unless run.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this run."
              redirect_with_flash(res, "/", alert: alert)
            end

            render_inertia(req, res, "Runs/Show", props: {
              run: run_props(run, user)
            })
          end

          private

          def run_props(run, _user)
            {
              id: run.id,
              status: run.status,
              published: run.published,
              role: run.role,
              harness: run.harness,
              model: run.model,
              producer: run.producer,
              created_at: run.created_at.iso8601,
              updated_at: run.updated_at.iso8601
            }
          end
        end
      end
    end
  end
end