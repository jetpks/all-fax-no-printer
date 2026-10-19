# frozen_string_literal: true

require_relative "../test_helper"

# I15 iteration-record store writers: upsert/replace-set round-trips at the
# repo level, on top of a real space → iteration chain.
class IterationRecordReposTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    # Children first. conversations.user_id has no ON DELETE CASCADE, so it
    # must die before users; the record tables have no dependents, but the
    # order is cheap insurance against any future FK additions.
    %i[verdict_rulings verdicts gate_results gates lanes messages conversations artifacts iterations spaces users].each do |t|
      conn[t].delete
    end
    @user      = Factory[:user]
    @space     = Factory[:space, user_id: @user.id]
    @iterations_repo = Space::Server::Repos::IterationsRepo.new
    @gates_repo      = Space::Server::Repos::GatesRepo.new
    @lanes_repo      = Space::Server::Repos::LanesRepo.new
    @gate_results_repo = Space::Server::Repos::GateResultsRepo.new
    @verdicts_repo     = Space::Server::Repos::VerdictsRepo.new
    @verdict_rulings_repo = Space::Server::Repos::VerdictRulingsRepo.new
  end

  def iteration
    @iteration ||= @iterations_repo.upsert_by_ordinal(@space.id, 15, name: "structured-iterations-ingest")
  end

  # --- GatesRepo -------------------------------------------------------------

  def test_gate_upsert_creates_then_updates_in_place
    gate = @gates_repo.upsert_by_gate_id(iteration.id, "g1", cmd: "rake test", ac: "AC1")
    assert_equal "g1", gate.gate_id
    assert_equal 1, conn[:gates].count

    updated = @gates_repo.upsert_by_gate_id(iteration.id, "g1", cmd: "rake test2")
    assert_equal gate.id, updated.id, "same row"
    assert_equal "rake test2", @gates_repo.by_pk(gate.id).cmd
    assert_equal 1, conn[:gates].count
  end

  def test_gate_replace_set_deletes_stale_rows
    @gates_repo.replace_for_iteration(iteration.id, [
      { gate_id: "g1", cmd: "one" },
      { gate_id: "g2", cmd: "two" }
    ])
    assert_equal %w[g1 g2], @gates_repo.gate_ids_for_iteration(iteration.id).sort

    @gates_repo.replace_for_iteration(iteration.id, [{ gate_id: "g1", cmd: "one" }])
    assert_equal ["g1"], @gates_repo.gate_ids_for_iteration(iteration.id), "stale gate must die"
  end

  def test_gate_replace_set_scoped_to_its_iteration
    other = @iterations_repo.upsert_by_ordinal(@space.id, 16, name: "other")
    @gates_repo.upsert_by_gate_id(other.id, "g1", cmd: "keep")

    @gates_repo.replace_for_iteration(iteration.id, [{ gate_id: "g9", cmd: "x" }])
    assert_equal ["g1"], @gates_repo.gate_ids_for_iteration(other.id), "other iteration untouched"
  end

  # --- LanesRepo ---------------------------------------------------------------

  def test_lane_upsert_creates_then_updates_in_place
    lane = @lanes_repo.upsert_by_name(iteration.id, "mouths", model: "glm")
    updated = @lanes_repo.upsert_by_name(iteration.id, "mouths", model: "pi")
    assert_equal lane.id, updated.id
    assert_equal "pi", @lanes_repo.by_pk(lane.id).model
    assert_equal 1, conn[:lanes].count
  end

  # --- GateResultsRepo ----------------------------------------------------------

  def test_gate_result_upsert_and_replace_for_lane
    gate = @gates_repo.upsert_by_gate_id(iteration.id, "g1", cmd: "one")
    lane = @lanes_repo.upsert_by_name(iteration.id, "mouths", {})

    first = @gate_results_repo.replace_for_lane(lane.id, [
      { iteration_gate_id: gate.id, status: "pass" }
    ])
    assert_equal 1, first.size

    @gate_results_repo.upsert(gate.id, lane.id, status: "fail")
    assert_equal "fail", @gate_results_repo.for_lane(lane.id).first.status, "same row updated"
    assert_equal 1, conn[:gate_results].count
  end

  def test_gate_result_replace_for_lane_deletes_stale
    g1 = @gates_repo.upsert_by_gate_id(iteration.id, "g1", cmd: "one")
    g2 = @gates_repo.upsert_by_gate_id(iteration.id, "g2", cmd: "two")
    lane = @lanes_repo.upsert_by_name(iteration.id, "mouths", {})

    @gate_results_repo.replace_for_lane(lane.id, [
      { iteration_gate_id: g1.id, status: "pass" },
      { iteration_gate_id: g2.id, status: "pass" }
    ])
    @gate_results_repo.replace_for_lane(lane.id, [
      { iteration_gate_id: g1.id, status: "pass" }
    ])
    assert_equal [g1.id], @gate_results_repo.for_lane(lane.id).map(&:iteration_gate_id), "stale result must die"
  end

  # --- VerdictsRepo / VerdictRulingsRepo -----------------------------------------

  def test_verdict_upsert_is_one_row_per_iteration
    v1 = @verdicts_repo.upsert_for_iteration(iteration.id, decision: "continue", phase0_resolutions: [])
    v2 = @verdicts_repo.upsert_for_iteration(iteration.id, decision: "kill", phase0_resolutions: [])
    assert_equal v1.id, v2.id
    assert_equal "kill", @verdicts_repo.for_iteration(iteration.id).decision
    assert_equal 1, conn[:verdicts].count
  end

  def test_verdict_rulings_replace_set
    verdict = @verdicts_repo.upsert_for_iteration(iteration.id, decision: "continue", phase0_resolutions: [])

    @verdict_rulings_repo.replace_for_verdict(verdict.id, [
      { ac: "AC1", ruling: "PASS" },
      { ac: "AC2", ruling: "FAIL", note: "gate red" }
    ])
    assert_equal %w[AC1 AC2], @verdict_rulings_repo.for_verdict(verdict.id).map(&:ac)

    @verdict_rulings_repo.replace_for_verdict(verdict.id, [{ ac: "AC1", ruling: "MODIFY" }])
    rulings = @verdict_rulings_repo.for_verdict(verdict.id)
    assert_equal ["AC1"], rulings.map(&:ac), "stale ruling must die"
    assert_equal "MODIFY", rulings.first.ruling
  end
end
