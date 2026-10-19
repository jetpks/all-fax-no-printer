# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      # Mouth 3 — POST /iterations/ingest/verdict. Ruling text is free-form
      # (house convention PASS/FAIL/MODIFY/NOT-APPLICABLE is convention, not
      # constraint).
      class IngestIterationVerdict < Dry::Validation::Contract
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

          required(:verdict).hash do
            required(:decision).value(:string, included_in?: %w[continue kill])
            optional(:ac_rulings).array(:hash) do
              required(:ac).filled(:string)
              required(:ruling).filled(:string)
              optional(:note).maybe(:string)
            end
            optional(:phase0_resolutions).array(:hash) do
              required(:topic).filled(:string)
              optional(:lane).maybe(:string)
              optional(:resolution).maybe(:string)
            end
          end
        end
      end
    end
  end
end
