# frozen_string_literal: true

require_relative "support"

class NormalizerTest < Minitest::Test
  test "selects Pi for a session/version first line" do
    assert_equal Space::Server::Normalizer::Pi,
                 Space::Server::Normalizer.select("type" => "session", "version" => 3, "id" => "abc")
  end

  test "selects Pi for pi_streaming_session fixture's first line" do
    line   = File.readlines(File.join(NORMALIZER_FIXTURE_DIR, "pi_streaming_session.jsonl"), chomp: true).first
    record = JSON.parse(line)
    assert_equal Space::Server::Normalizer::Pi, Space::Server::Normalizer.select(record)
  end

  test "a session-typed record without a version key selects nothing" do
    assert_nil Space::Server::Normalizer.select("type" => "session", "session_id" => "abc")
  end

  test "a non-session record selects nothing — no fallback parser" do
    assert_nil Space::Server::Normalizer.select("part" => {}, "type" => "step_start")
    assert_nil Space::Server::Normalizer.select("sessionId" => "aabbccdd")
    assert_nil Space::Server::Normalizer.select("sessionID" => "ses_abc")
    assert_nil Space::Server::Normalizer.select("type" => "system", "session_id" => "abc")
  end
end