# frozen_string_literal: true

module Space
  module Server
    module Repos
      class LanesRepo < Space::Server::DB::Repo
        def for_iteration(iteration_id)
          lanes.where(iteration_id: iteration_id).order(:name).to_a
        end

        def by_pk(id)
          lanes.by_pk(id).one
        end

        # Find-or-create with update on match, keyed (iteration_id, name).
        # Only present attrs are written — scalar upsert, not wholesale
        # replace. Returns the upserted Lane struct.
        def upsert_by_name(iteration_id, name, attrs)
          existing = lanes.where(iteration_id: iteration_id, name: name).to_a.first
          now = Time.now
          if existing
            lanes.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            lanes.by_pk(existing.id).one
          else
            lanes.command(:create).call(
              attrs.merge(iteration_id: iteration_id, name: name, created_at: now, updated_at: now)
            )
          end
        end
      end
    end
  end
end
