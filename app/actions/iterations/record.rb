# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Iterations
        # The record read — GET /spaces/:id/iterations/:ordinal serves the full
        # structured record for ENTRY 2's end-to-end proof. Owner-scoped via
        # authenticated_user (session OR bearer); anonymous, non-owner, unknown
        # space, or unknown ordinal → 404 JSON. TRANSCRIPTS APPEAR ONLY HERE
        # (machine read, full fidelity) — never in the show props (phone-page
        # weight).
        class Record < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo", "repos.iterations_repo", "repos.gates_repo",
            "repos.lanes_repo", "repos.gate_results_repo", "repos.verdicts_repo",
            "repos.verdict_rulings_repo"
          ]

          def handle(req, res)
            user = authenticated_user(req)
            space = spaces_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless space && user && space.visible_to?(user)

            iteration = iterations_repo.find_by_ordinal(space.id, req.params[:ordinal].to_i)
            halt_not_found(res) unless iteration

            render_json(res, record_json(space, iteration))
          end

          private

          def record_json(space, iteration)
            { space: { id: space.id, slug: space.slug },
              iteration: iteration_json(iteration) }
          end

          def iteration_json(iteration)
            gates = gates_repo.for_iteration(iteration.id)
            verdict = verdicts_repo.for_iteration(iteration.id)

            {
              id:          iteration.id,
              ordinal:     iteration.ordinal,
              name:        iteration.name,
              slug:        iteration.slug,
              freeze_sha:  iteration.freeze_sha,
              branch:      iteration.branch,
              status:      iteration.status,
              verdict:     iteration.verdict,
              created_at:  iteration.created_at&.iso8601(6),
              occurred_at: iteration.occurred_at&.iso8601(6),
              gates:          gates.map { |g| gate_json(g) },
              lanes:          lanes_repo.for_iteration(iteration.id).map { |l| lane_json(l, gates) },
              verdict_detail: verdict && verdict_detail_json(verdict)
            }
          end

          def gate_json(gate)
            { gate_id: gate.gate_id, ac: gate.ac, cwd: gate.cwd, cmd: gate.cmd,
              timeout: timeout_json(gate.timeout), expect: gate.expect }
          end

          # pg numeric arrives as BigDecimal and JSON's BigDecimal path emits
          # exponent form ("0.6e3") — emit a plain number instead (Integer when
          # integral, Float otherwise).
          def timeout_json(timeout)
            return nil if timeout.nil?

            timeout.is_a?(BigDecimal) && timeout == timeout.to_i ? timeout.to_i : timeout.to_f
          end

          def lane_json(lane, gates)
            gate_label = gates.to_h { |g| [g.id, g.gate_id] }
            {
              name:                   lane.name,
              repo:                   lane.repo,
              base_sha:               lane.base_sha,
              model:                  lane.model,
              harness:                lane.harness,
              effort:                 lane.effort,
              touch_set:              Array(lane.touch_set),
              status:                 lane.status,
              bounds_override_reason: lane.bounds_override_reason,
              escalations:            Array(lane.escalations),
              merge_sha:              lane.merge_sha,
              integration_branch:     lane.integration_branch,
              integrated_at:          lane.integrated_at&.iso8601(6),
              # Deterministic order: by gate_id label, not row-insertion order.
              gate_results: gate_results_repo.for_lane(lane.id)
                                             .sort_by { |r| gate_label[r.iteration_gate_id].to_s }
                                             .map { |r| result_json(r, gate_label) }
            }
          end

          def result_json(result, gate_label)
            { gate_id: gate_label[result.iteration_gate_id], status: result.status,
              reason: result.reason, transcript: result.transcript }
          end

          def verdict_detail_json(verdict)
            {
              decision:           verdict.decision,
              ac_rulings:         verdict_rulings_repo.for_verdict(verdict.id).map { |r| ruling_json(r) },
              phase0_resolutions: verdict.phase0_resolutions
            }
          end

          def ruling_json(ruling)
            { ac: ruling.ac, ruling: ruling.ruling, note: ruling.note }
          end
        end
      end
    end
  end
end
