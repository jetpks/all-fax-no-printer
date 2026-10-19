# frozen_string_literal: true

module Space
  module Server
    module Repos
      class VerdictRulingsRepo < Space::Server::DB::Repo
        def for_verdict(verdict_id)
          verdict_rulings.where(verdict_id: verdict_id).order(:ac).to_a
        end

        def by_pk(id)
          verdict_rulings.by_pk(id).one
        end

        # Upsert keyed (verdict_id, ac). Only present attrs are written.
        # Returns the upserted VerdictRuling struct.
        def upsert(verdict_id, ac, attrs)
          existing = verdict_rulings.where(verdict_id: verdict_id, ac: ac).to_a.first
          now = Time.now
          if existing
            verdict_rulings.by_pk(existing.id).command(:update).call(attrs.merge(updated_at: now))
            verdict_rulings.by_pk(existing.id).one
          else
            verdict_rulings.command(:create).call(
              attrs.merge(verdict_id: verdict_id, ac: ac, created_at: now, updated_at: now)
            )
          end
        end

        # An emission is the COMPLETE truth for its facet: every payload row is
        # upserted on its natural key, and the verdict's stored rows keyed
        # outside the payload die. Returns the upserted structs.
        def replace_for_verdict(verdict_id, rows)
          upserted = rows.map { |row| upsert(verdict_id, row[:ac], row.except(:ac)) }
          keep = rows.map { |row| row[:ac] }
          verdict_rulings.dataset.where(verdict_id: verdict_id).exclude(ac: keep).delete
          upserted
        end
      end
    end
  end
end
