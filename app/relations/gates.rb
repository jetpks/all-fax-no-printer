# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Gates < Space::Server::DB::Relation
        schema(:gates, infer: true) do
          associations do
            belongs_to :iteration
          end
        end
      end
    end
  end
end
