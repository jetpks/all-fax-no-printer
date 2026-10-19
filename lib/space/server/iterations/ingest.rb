# frozen_string_literal: true

module Space
  module Server
    module Iterations
      # The structured-record ingest semantics behind the four bearer mouths
      # (POST /iterations/ingest/{freeze,lane,verdict,integration}). Actions
      # stay thin: auth, slug, contract — then this service owns everything
      # else. Posture: MODELED FIRST — the JSON payload is the complete truth
      # for its facet: scalar fields upsert (present non-nil values overwrite,
      # absent keys leave stored values untouched), child sets REPLACE (every
      # payload row upserted on its natural key, stored rows keyed outside the
      # payload deleted). Order-tolerant: a later-mouth POST may arrive before
      # the freeze POST — iteration/lane stubs are created on demand.
      class Ingest
        # Optional iteration-hash strings that upsert onto the row when
        # present (non-nil). ordinal/name are handled separately.
        ITERATION_OPTIONAL_ATTRS = %i[slug freeze_sha branch status].freeze

        # Lane scalar fields written by the lane mouth (integrated_at,
        # merge_sha, integration_branch belong to the integration mouth).
        LANE_SCALAR_ATTRS = %i[repo base_sha model harness effort status bounds_override_reason].freeze

        def initialize(spaces_repo:, iterations_repo:, gates_repo:, lanes_repo:, gate_results_repo:, verdicts_repo:, verdict_rulings_repo:)
          @spaces_repo        = spaces_repo
          @iterations_repo    = iterations_repo
          @gates_repo         = gates_repo
          @lanes_repo         = lanes_repo
          @gate_results_repo  = gate_results_repo
          @verdicts_repo      = verdicts_repo
          @verdict_rulings_repo = verdict_rulings_repo
        end

        # Mouth 1 — freeze: iteration identity + the frozen gate set (replace
        # set keyed (iteration_id, gate_id), fields stored verbatim).
        def freeze(space_id, payload)
          iteration = resolve_iteration(space_id, payload[:iteration])
          applied = 0
          if payload.key?(:gates)
            rows = payload[:gates].map do |gate|
              { gate_id: gate[:id], ac: gate[:ac], cwd: gate[:cwd], cmd: gate[:cmd],
                timeout: gate[:timeout], expect: gate[:expect] }.compact
            end
            applied = @gates_repo.replace_for_iteration(iteration.id, rows).size
          end

          { iteration: iteration, gates_applied: applied }
        end

        # Mouth 2 — lane: lane disposition upsert keyed (iteration_id, name);
        # gate results replace set keyed (iteration_gate_id, lane_id). Every
        # gate_id must reference a stored gate of the same iteration — checked
        # BEFORE any write, so a rejection applies nothing.
        def lane(space_id, payload)
          iteration = resolve_iteration(space_id, payload[:iteration])
          lane_payload = payload[:lane]
          gate_results = lane_payload[:gate_results]

          if gate_results
            unknown = gate_results.map { it[:gate_id] } - @gates_repo.gate_ids_for_iteration(iteration.id)
            return { error: "unknown gate ids: #{unknown.join(", ")}" } if unknown.any?
          end

          lane = @lanes_repo.upsert_by_name(iteration.id, lane_payload[:name], lane_attrs(lane_payload))
          applied = 0
          if gate_results
            rows = gate_results.map do |result|
              gate = @gates_repo.for_iteration(iteration.id).find { |g| g.gate_id == result[:gate_id] }
              { iteration_gate_id: gate.id, status: result[:status],
                reason: result[:reason], transcript: result[:transcript] }.compact
            end
            applied = @gate_results_repo.replace_for_lane(lane.id, rows).size
          end

          { iteration: iteration, lane: lane, gate_results_applied: applied }
        end

        # Mouth 3 — verdict: verdict upsert (UNIQUE iteration); ac rulings
        # replace set keyed (verdict_id, ac); phase0 resolutions stored
        # verbatim. The decision mirrors onto iterations.verdict (parity with
        # the current show rendering) — via the repo's own upsert attrs, no
        # new iterations_repo method.
        def verdict(space_id, payload)
          iteration = resolve_iteration(space_id, payload[:iteration])
          verdict_payload = payload[:verdict]

          verdict_attrs = { decision: verdict_payload[:decision] }
          if verdict_payload.key?(:phase0_resolutions)
            verdict_attrs[:phase0_resolutions] = verdict_payload[:phase0_resolutions]
          end
          verdict = @verdicts_repo.upsert_for_iteration(iteration.id, verdict_attrs)

          applied = 0
          if verdict_payload.key?(:ac_rulings)
            rows = verdict_payload[:ac_rulings].map do |ruling|
              { ac: ruling[:ac], ruling: ruling[:ruling], note: ruling[:note] }.compact
            end
            applied = @verdict_rulings_repo.replace_for_verdict(verdict.id, rows).size
          end

          @iterations_repo.upsert_by_ordinal(space_id, iteration.ordinal, verdict: verdict_payload[:decision])

          { iteration: iteration, verdict: verdict, ac_rulings_applied: applied }
        end

        # Mouth 4 — integration: per lane entry, upsert the lane row keyed
        # (iteration_id, name) with merge_sha/integration_branch/integrated_at
        # — creating a stub lane row when the lane-completion emission never
        # landed (order tolerance). A lane entry without its own
        # integration_branch falls back to the integration-level branch.
        def integration(space_id, payload)
          iteration = resolve_iteration(space_id, payload[:iteration])
          integration_payload = payload[:integration]

          integrated = 0
          integration_payload[:lanes].each do |entry|
            attrs = { integrated_at: Time.now }
            attrs[:merge_sha] = entry[:merge_sha] if entry[:merge_sha]
            branch = entry[:integration_branch] || integration_payload[:branch]
            attrs[:integration_branch] = branch if branch
            @lanes_repo.upsert_by_name(iteration.id, entry[:name], attrs)
            integrated += 1
          end

          { iteration: iteration, lanes_integrated: integrated }
        end

        private

        # Find-or-create by (space_id, ordinal) — the stub carries the payload
        # name; optional scalar strings upsert when present.
        def resolve_iteration(space_id, iteration_payload)
          attrs = { name: iteration_payload[:name] }
          ITERATION_OPTIONAL_ATTRS.each do |key|
            attrs[key] = iteration_payload[key] if iteration_payload[key]
          end
          @iterations_repo.upsert_by_ordinal(space_id, iteration_payload[:ordinal], attrs)
        end

        # Scalar upsert: only present (non-nil) values are written, so an
        # emission's absent keys leave stored values untouched.
        def lane_attrs(lane_payload)
          attrs = { touch_set: lane_payload[:touch_set], escalations: lane_payload[:escalations] }
          LANE_SCALAR_ATTRS.each do |key|
            attrs[key] = lane_payload[key] if lane_payload[key]
          end
          attrs.compact
        end
      end
    end
  end
end
