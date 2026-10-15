# auto_register: false
# frozen_string_literal: true

require "dry/validation"

module Space
  module Server
    module Contracts
      # A minted API token is a name plus server-generated secret material —
      # the client supplies only a human-readable label. No token material is
      # ever accepted from the request.
      class CreateAPIToken < Dry::Validation::Contract
        params do
          required(:name).filled(:string)
        end
      end
    end
  end
end
