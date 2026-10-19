# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Verdicts < Space::Server::DB::Relation
        schema(:verdicts, infer: true) do
          associations do
            belongs_to :iteration
          end
        end
      end
    end
  end
end
