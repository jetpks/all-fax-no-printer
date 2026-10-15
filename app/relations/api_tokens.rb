# frozen_string_literal: true

module Space
  module Server
    module Relations
      class APITokens < Space::Server::DB::Relation
        schema(:api_tokens, infer: true) do
          associations do
            belongs_to :user
          end
        end
      end
    end
  end
end
