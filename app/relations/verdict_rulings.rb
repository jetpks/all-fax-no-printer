# frozen_string_literal: true

module Space
  module Server
    module Relations
      class VerdictRulings < Space::Server::DB::Relation
        schema(:verdict_rulings, infer: true) do
          associations do
            belongs_to :verdict
          end
        end
      end
    end
  end
end
