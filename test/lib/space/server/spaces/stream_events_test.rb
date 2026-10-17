# frozen_string_literal: true

require_relative "../../../../test_helper"
require "space/server/spaces/stream_events"

# looplog 9.6.0 parity for the space stream's display tag: the full agent
# name, verbatim — no abbrev map (forwards compatible with new roles).
# ingest stores agent_name as the full name and agent_role as the name minus
# the "architect-" prefix (session-sink agentRoleFor); the name wins, the
# stripped role shows as-is when it's all there is, and a conversation with
# neither falls back to the bare id.
class StreamEventsTagTest < Minitest::Test
  include Space::Server::Spaces::StreamEvents

  def test_full_agent_name_shows_verbatim
    assert_equal "architect-coordinator", tag(1, "coordinator", "architect-coordinator")
    assert_equal "architect-narrator", tag(1, "narrator", "architect-narrator")
  end

  def test_unknown_agent_name_shows_verbatim
    assert_equal "architect-research", tag(1, "research", "architect-research"), "no abbrev map — nothing to abbreviate"
    assert_equal "Navi the Navigator", tag(1, nil, "Navi the Navigator"), "no clipping either"
  end

  def test_role_without_name_shows_the_role_as_stored
    assert_equal "coordinator", tag(1, "coordinator", nil)
    assert_equal "bld", tag(1, "bld", nil)
  end

  def test_neither_name_nor_role_falls_back_to_the_conversation_id
    assert_equal "conv-42", tag(42, nil, nil)
    assert_equal "conv-42", tag(42, nil, "")
  end
end
