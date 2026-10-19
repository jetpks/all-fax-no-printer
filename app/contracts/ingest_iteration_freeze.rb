# auto_register: false
# frozen_string_literal: true

require "dry/validation"
require "dry/types"

module Space
  module Server
    module Contracts
      # Mouth 1 — POST /iterations/ingest/freeze (identity + the frozen gates,
      # emitted at `architect freeze`). Mirrors the emitting CLI's gate-lint
      # contract (required id/ac/cmd, optional cwd/timeout/expect, unknown
      # keys rejected) minus its regexp capture-group-count rule — the CLI
      # lints its own gates; the server validates store shape.
      class IngestIterationFreeze < Dry::Validation::Contract
        config.validate_keys = true

        NUMBER = Dry::Types["integer"] | Dry::Types["float"]
        EXPECT_OPS = %w[>= <= > < == !=].freeze

        params do
          required(:iteration).hash do
            required(:ordinal).value(:integer, gt?: 0)
            required(:name).filled(:string)
            optional(:slug).maybe(:string)
            optional(:freeze_sha).maybe(:string)
            optional(:branch).maybe(:string)
            optional(:status).maybe(:string)
          end

          optional(:gates).array(:hash) do
            required(:id).filled(:string)
            required(:ac).filled(:string)
            required(:cmd).filled(:string)
            optional(:cwd).maybe(:string)
            optional(:timeout).maybe(NUMBER)
            optional(:expect).hash do
              optional(:exit_code).value(:integer)
              optional(:stdout_match).maybe(:string)
              optional(:threshold).hash do
                required(:match).filled(:string)
                required(:op).value(:string, included_in?: EXPECT_OPS)
                required(:value).value(NUMBER)
              end
            end
          end
        end

        rule(:gates) do
          next unless key?

          value.each_with_index do |gate, i|
            key([:gates, i]).failure("must be greater than 0") if gate[:timeout] && gate[:timeout] <= 0
            key([:gates, i]).failure("must include at least one key") if gate[:expect] && gate[:expect].empty?
          end
        end
      end
    end
  end
end
