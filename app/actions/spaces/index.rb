# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Index < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.conversations_repo"
          ]

          def handle(req, res)
            user   = current_user(req)
            spaces = spaces_repo.list_visible_to(user)

            space_list = spaces.map do |space|
              {
                id:                  space.id,
                slug:                space.slug,
                title:               space.title,
                status:              space.status.to_s,
                iterations_count:    iterations_repo.count_for_space(space.id),
                conversations_count: spaces_repo.conversations_count(space.id),
                last_activity_at:    spaces_repo.last_activity_at(space.id)&.utc&.iso8601(6)
              }
            end

            # Unspaced: the viewer's space-less conversations bucketed by the
            # session's working directory — spaces are implicit from cwd when
            # no slug header linked one. Per-cwd buckets drill down via
            # /conversations?cwd=…
            unspaced = conversations_repo.unspaced_cwd_buckets(user).map do |bucket|
              {
                cwd:                bucket[:original_cwd],
                conversations_count: bucket[:conversations_count],
                last_activity_at:   bucket[:last_activity_at]&.utc&.iso8601(6)
              }
            end

            render_inertia(req, res, "Spaces/Index", props: { spaces: space_list, unspaced: unspaced })
          end
        end
      end
    end
  end
end
