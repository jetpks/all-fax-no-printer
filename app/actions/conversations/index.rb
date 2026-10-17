# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo", "repos.spaces_repo"]

          def handle(req, res)
            user = current_user(req)
            page = clamped_page(req)
            space_id = req.params[:space_id]&.to_i
            cwd = req.params[:cwd]

            # ?space_id= narrows to one space; a space the viewer cannot see is
            # hidden like any other private space (existence-hiding).
            space = space_id && spaces_repo.by_pk(space_id)
            if space_id && (space.nil? || !space.visible_to?(user))
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            paged = conversations_repo.visible_to(user, page: page, space_id: space_id, cwd: cwd)
            conversation_list = paged[:rows].map do |conv|
              Serializers::Conversation.conversation_list_json(conv, viewer: user)
            end

            props = {
              conversations: conversation_list,
              pagination: { page: page, has_more: paged[:has_more] }
            }
            props[:space] = { id: space.id, slug: space.slug, title: space.title } if space
            props[:cwd] = cwd if cwd

            render_inertia(req, res, "Conversations/Index", props: props)
          end

          private

          def clamped_page(req)
            page = req.params[:page].to_i
            page.positive? ? page : 1
          end
        end
      end
    end
  end
end
