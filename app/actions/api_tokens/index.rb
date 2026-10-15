# frozen_string_literal: true

module Space
  module Server
    module Actions
      module APITokens
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.api_tokens_repo"]

          def handle(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "ApiTokens/Index", props: { tokens: token_list(user) })
          end

          private

          def token_list(user)
            api_tokens_repo.list_by_user(user.id).map do |token|
              {
                id:           token.id,
                name:         token.name,
                created_at:   token.created_at.iso8601,
                last_used_at: token.last_used_at&.iso8601,
                revoked_at:   token.revoked_at&.iso8601
              }
            end
          end
        end
      end
    end
  end
end
