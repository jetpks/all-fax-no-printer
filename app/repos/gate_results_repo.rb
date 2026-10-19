# frozen_string_literal: true

module Space
  module Server
    module Repos
      class GateResultsRepo < Space::Server::DB::Repo
        def for_lane(lane_id)
          gate_results.where(lane_id: lane_id).order(:iteration_gate_id).to_a
        end

        def for_iteration_gate(iteration_gate_id)
          gate_results.where(iteration_gate_id: iteration_gate_id).to_a
        end

        def by_pk(id)
          gate_results.by_pk(id).one
        end

        # Upsert keyed (iteration_gate_id, lane_id). Only present attrs are
        # written. Returns the upserted GateResult struct.
        def upsert(iteration_gate_id, lane_id, attrs)
          existing = gate_results.where(iteration_gate_id: iteration_gate_id, lane_id: lane_id).to_a.first
          now = Time.now
          if existing
            gate_results.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            gate_results.by_pk(existing.id).one
          else
            gate_results.command(:create).call(
              attrs.merge(iteration_gate_id: iteration_gate_id, lane_id: lane_id, created_at: now, updated_at: now)
            )
          end
        end

        # An emission is the COMPLETE truth for its facet: every payload row is
        # upserted on its natural key, and the lane's stored rows keyed outside
        # the payload die. Returns the upserted structs.
        def replace_for_lane(lane_id, rows)
          upserted = rows.map { |row| upsert(row[:iteration_gate_id], lane_id, row.except(:iteration_gate_id)) }
          keep = rows.map { |row| row[:iteration_gate_id] }
          gate_results.dataset.where(lane_id: lane_id).exclude(iteration_gate_id: keep).delete
          upserted
        end
      end
    end
  end
end
