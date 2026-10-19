# frozen_string_literal: true

module Space
  module Server
    module Repos
      class GatesRepo < Space::Server::DB::Repo
        def for_iteration(iteration_id)
          gates.where(iteration_id: iteration_id).order(:gate_id).to_a
        end

        def gate_ids_for_iteration(iteration_id)
          gates.dataset.where(iteration_id: iteration_id).select_map(:gate_id)
        end

        def by_pk(id)
          gates.by_pk(id).one
        end

        # Find-or-create with update on match, keyed (iteration_id, gate_id).
        # Only present attrs are written — scalar upsert, not wholesale replace.
        # Returns the upserted Gate struct.
        def upsert_by_gate_id(iteration_id, gate_id, attrs)
          existing = gates.where(iteration_id: iteration_id, gate_id: gate_id).to_a.first
          now = Time.now
          if existing
            gates.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            gates.by_pk(existing.id).one
          else
            gates.command(:create).call(
              attrs.merge(iteration_id: iteration_id, gate_id: gate_id, created_at: now, updated_at: now)
            )
          end
        end

        # An emission is the COMPLETE truth for its facet: every payload row is
        # upserted on its natural key, and stored rows keyed outside the
        # payload die. Returns the upserted structs.
        def replace_for_iteration(iteration_id, rows)
          upserted = rows.map { |row| upsert_by_gate_id(iteration_id, row[:gate_id], row.except(:gate_id)) }
          keep = rows.map { |row| row[:gate_id] }
          gates.dataset.where(iteration_id: iteration_id).exclude(gate_id: keep).delete
          upserted
        end
      end
    end
  end
end
