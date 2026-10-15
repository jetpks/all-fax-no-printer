# frozen_string_literal: true

module Space
  module Server
    module Actions
      module APITokens
        class New < Space::Server::Action
          def handle(req, res)
            require_login(req, res)
            render_inertia(req, res, "ApiTokens/New")
          end
        end
      end
    end
  end
end
