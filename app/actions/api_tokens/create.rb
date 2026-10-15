# frozen_string_literal: true

require_relative "../../contracts/create_api_token"

module Space
  module Server
    module Actions
      module APITokens
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.api_tokens_repo"]

          CONTRACT = Contracts::CreateAPIToken.new

          # CONTRACT's params are flat, so the field-path mapping is the
          # identity — kept explicit anyway, mirroring Providers::Create.
          FIELD_PATHS = { name: [:name] }.freeze

          def handle(req, res)
            user = require_login(req, res)

            result = CONTRACT.call(req.params.to_h)
            redirect_inertia(req, res, "/api_tokens/new", errors: field_errors(result.errors.to_h)) if result.failure?

            secret, token = api_tokens_repo.create(user_id: user.id, name: result.to_h[:name])
            # The plaintext secret rides this one response as page props — it is
            # never persisted, and a revisit/refresh of /api_tokens/new computes
            # fresh props, so it can only ever render once.
            render_inertia(req, res, "ApiTokens/New", props: { minted: { name: token.name, secret: secret } })
          end

          private

          def field_errors(errors)
            FIELD_PATHS.each_with_object({}) do |(field, path), out|
              node = dig_hash(errors, *path)
              out[field] = flatten_messages(node).join(", ") unless node.nil?
            end
          end

          # Plain Hash#dig raises TypeError when an intermediate node is an Array —
          # see Profiles::Create's identical guard for the same crash.
          def dig_hash(node, *path)
            path.reduce(node) do |current, key|
              break nil unless current.is_a?(Hash)

              current[key]
            end
          end

          def flatten_messages(node)
            case node
            when String then [node]
            when Array  then node.flat_map { |v| flatten_messages(v) }
            when Hash   then node.values.flat_map { |v| flatten_messages(v) }
            else []
            end
          end
        end
      end
    end
  end
end
