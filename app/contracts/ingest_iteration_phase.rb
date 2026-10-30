# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      # Mouth 5 — POST /iterations/ingest/phase (the loop's CURRENT phase per
      # iteration, pinged by `architect ping` at spec-launched /
      # builders-settled / judge-running). kind is free text at the mouth —
      # the status discipline: free text at the mouth, frozen vocabulary at
      # the emitter. The iteration block is the exact shape the other mouths
      # share.
      class IngestIterationPhase < Dry::Validation::Contract
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

          required(:phase).hash do
            required(:kind).filled(:string)
            optional(:note).maybe(:string)
          end
        end
      end
    end
  end
end
