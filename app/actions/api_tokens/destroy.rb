# frozen_string_literal: true

module Space
  module Server
    module Actions
      module APITokens
        # Destroy is a soft revoke — the row (and its hash) survives with a
        # revoked_at stamp so mint history stays auditable; the token simply
        # stops authenticating.
        class Destroy < Space::Server::Action
          include Space::Server::Deps["repos.api_tokens_repo"]

          def handle(req, res)
            user = require_login(req, res)

            token = api_tokens_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless token && token.user_id == user.id

            api_tokens_repo.revoke(token.id)
            res.flash["notice"] = "Token revoked."
            redirect_inertia(req, res, "/api_tokens")
          end
        end
      end
    end
  end
end
