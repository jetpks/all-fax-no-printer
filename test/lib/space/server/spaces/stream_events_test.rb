# frozen_string_literal: true

require_relative "../../../../test_helper"
require "space/server/spaces/stream_events"

# looplog 9.5.0 parity for the space stream's display tag: known architect
# agents abbreviate by their FULL agent name; ingest stores the role as the
# name minus the "architect-" prefix (session-sink agentRoleFor), so both
# forms must hit the map; unknown names clip to 10 chars (looplog's fetch
# fallback); neither name nor role → the bare conversation id.
class StreamEventsTagTest < Minitest::Test
  include Space::Server::Spaces::StreamEvents

  def test_full_agent_name_abbreviates
    assert_equal "coord", tag(1, nil, "architect-coordinator")
    assert_equal "narr", tag(1, nil, "architect-narrator")
  end

  def test_prefix_stripped_role_abbreviates
    assert_equal "coord", tag(1, "coordinator", nil)
    assert_equal "bld", tag(1, "builder", nil)
  end

  def test_production_shape_full_name_plus_stripped_role_abbreviates
    assert_equal "coord", tag(1, "coordinator", "architect-coordinator")
  end

  def test_unknown_agent_name_clips_to_ten_chars
    assert_equal "architect-", tag(1, "research", "architect-research"), "looplog parity: unknown agents clip"
    assert_equal "Navi the N", tag(1, nil, "Navi the Navigator")
  end

  def test_neither_name_nor_role_falls_back_to_the_conversation_id
    assert_equal "conv-42", tag(42, nil, nil)
    assert_equal "conv-42", tag(42, nil, "")
  end
end
