# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Lanes < Space::Server::DB::Relation
        schema(:lanes, infer: true) do
          associations do
            belongs_to :iteration
          end
        end
      end
    end
  end
end
