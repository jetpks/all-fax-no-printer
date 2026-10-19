# frozen_string_literal: true

module Space
  module Server
    module Relations
      class GateResults < Space::Server::DB::Relation
        schema(:gate_results, infer: true) do
          associations do
            # The gates FK is named iteration_gate_id (a gate row belongs to an
            # iteration AND carries its gate_id label), so the association is
            # pinned explicitly rather than left to FK inference.
            belongs_to :gate, foreign_key: :iteration_gate_id
            belongs_to :lane
          end
        end
      end
    end
  end
end
