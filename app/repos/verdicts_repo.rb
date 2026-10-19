# frozen_string_literal: true

module Space
  module Server
    module Repos
      class VerdictsRepo < Space::Server::DB::Repo
        # One verdict row per iteration (UNIQUE iteration_id).
        def for_iteration(iteration_id)
          verdicts.where(iteration_id: iteration_id).to_a.first
        end

        def by_pk(id)
          verdicts.by_pk(id).one
        end

        # Find-or-create with update on match, keyed iteration_id (the row IS
        # the iteration's verdict). Returns the upserted Verdict struct.
        def upsert_for_iteration(iteration_id, attrs)
          existing = verdicts.where(iteration_id: iteration_id).to_a.first
          now = Time.now
          if existing
            verdicts.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            verdicts.by_pk(existing.id).one
          else
            verdicts.command(:create).call(
              attrs.merge(iteration_id: iteration_id, created_at: now, updated_at: now)
            )
          end
        end
      end
    end
  end
end
