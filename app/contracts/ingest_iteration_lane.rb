# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      # Mouth 2 — POST /iterations/ingest/lane (lane completion). Gate-result
      # gate_ids are validated against stored gates by the service (they need
      # DB access); this contract pins the payload shape.
      class IngestIterationLane < Dry::Validation::Contract
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

          required(:lane).hash do
            required(:name).filled(:string)
            optional(:repo).maybe(:string)
            optional(:base_sha).maybe(:string)
            optional(:model).maybe(:string)
            optional(:harness).maybe(:string)
            optional(:effort).maybe(:string)
            optional(:status).maybe(:string)
            optional(:bounds_override_reason).maybe(:string)
            optional(:touch_set).array(:string)
            optional(:escalations).array(:hash) do
              required(:topic).filled(:string)
              optional(:ruling).maybe(:string)
              optional(:note).maybe(:string)
            end
            optional(:gate_results).array(:hash) do
              required(:gate_id).filled(:string)
              required(:status).value(:string, included_in?: %w[pass fail])
              optional(:reason).maybe(:string)
              optional(:transcript).maybe(:string)
            end
          end
        end
      end
    end
  end
end
