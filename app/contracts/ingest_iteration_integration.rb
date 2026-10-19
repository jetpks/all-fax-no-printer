# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      # Mouth 4 — POST /iterations/ingest/integration.
      class IngestIterationIntegration < Dry::Validation::Contract
        config.validate_keys = true

        params do
          required(:iteration).hash do
            required(:ordinal).value(:integer, gt?: 0)
            required(:name).filled(:string)
            optional(:slug).maybe(:string)
            optional(:freeze_sha).maybe(:string)
            optional(:branch).maybe(:string)
            optional(:status).maybe(:string)
          end

          required(:integration).hash do
            optional(:branch).maybe(:string)
            required(:lanes).array(:hash) do
              required(:name).filled(:string)
              optional(:merge_sha).maybe(:string)
              optional(:integration_branch).maybe(:string)
            end
          end
        end

        rule(:integration) do
          key.failure("must have at least one lane") if value && value[:lanes] && value[:lanes].empty?
        end
      end
    end
  end
end
