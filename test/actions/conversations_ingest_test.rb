# frozen_string_literal: true

require_relative "action_test_helper"
require "async"

class ConversationsIngestActionTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "ingest-secret-test-token-deadbeef0123456789"

  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_streaming_session.jsonl"))
  SPACE_FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_streaming_space_session.jsonl"))
  CHILD_FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_child_session.jsonl"))
  NUL_FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "pi_streaming_with_nul.jsonl"))
  MINIMAL_JSONL = "{\"type\":\"session\",\"version\":3,\"id\":\"minimal\",\"cwd\":\"/test\"}\n"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner     = Factory[:user, github_uid: "mouth-owner", username: "mouth_owner"]
    @other     = Factory[:user, github_uid: "mouth-other", username: "mouth_other"]
    @conversations_repo = Space::Server::App["repos.conversations_repo"]
    @messages_repo      = Space::Server::App["repos.messages_repo"]
    @api_tokens_repo    = Space::Server::App["repos.api_tokens_repo"]
    @settings  = Space::Server::App["settings"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def with_token_settings(token: TOKEN, user_id: nil)
    user_id ||= @owner.id
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
  end

  def mint_token(user, name = "cli")
    @api_tokens_repo.create(user_id: user.id, name: name)
  end

  # Headers keyed by their wire names; translated to the CGI env keys Rack
  # actions read.
  HEADER_ENV = {
    "X-Space-Slug"        => "HTTP_X_SPACE_SLUG",
    "X-Parent-Session-Id" => "HTTP_X_PARENT_SESSION_ID",
    "X-Agent-Role"        => "HTTP_X_AGENT_ROLE",
    "X-Agent-Name"        => "HTTP_X_AGENT_NAME",
    "X-Session-Complete"  => "HTTP_X_SESSION_COMPLETE"
  }.freeze

  def post_ingest(body, headers: {}, bearer: nil)
    env = Rack::MockRequest.env_for(
      "/conversations/ingest",
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/x-ndjson",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    headers.each { |k, v| env[HEADER_ENV.fetch(k)] = v }
    app.call(env)
  end

  # --- auth: no bearer → 401; bearer → attribution -------------------------------

  def test_no_bearer_returns_401_json_error
    status, _, body = post_ingest(FIXTURE_JSONL)
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_wrong_bearer_returns_401
    with_token_settings do
      status, _, body = post_ingest(FIXTURE_JSONL, bearer: "wrong-token")
      assert_equal 401, status
      assert parse_json(body).key?("error")
    end
  end

  def test_signed_in_session_without_bearer_still_401s_machine_mouth
    sign_in(@owner)
    status, _, body = post_ingest(FIXTURE_JSONL)
    assert_equal 401, status, "the mouth is bearer-only: a session cookie is not a machine token"
    assert parse_json(body).key?("error")
  end

  def test_sat_token_attribution
    user = Factory[:user, github_uid: "sat-owner", username: "sat_owner"]
    secret, = mint_token(user)

    status, _, body = post_ingest(FIXTURE_JSONL, bearer: secret)
    assert_equal 202, status
    conv = @conversations_repo.by_pk(parse_json(body)["id"])
    assert_equal user.id, conv.user_id, "conversation attributed to the token's owner"
  end

  def test_global_fallback_attribution_to_ingest_user
    with_token_settings(user_id: @owner.id) do
      status, _, body = post_ingest(FIXTURE_JSONL, bearer: TOKEN)
      assert_equal 202, status
      conv = @conversations_repo.by_pk(parse_json(body)["id"])
      assert_equal @owner.id, conv.user_id, "global INGEST_TOKEN attributes to ingest_user_id"
    end
  end

  def test_revoked_token_returns_401
    user = Factory[:user, github_uid: "token-revoked", username: "token_revoked"]
    secret, token = mint_token(user)
    post_ingest(MINIMAL_JSONL, bearer: secret)

    @api_tokens_repo.revoke(token.id)
    status, _, body = post_ingest(MINIMAL_JSONL, bearer: secret)
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_nil_ingest_token_with_bearer_returns_401
    status, _, _ = post_ingest(FIXTURE_JSONL, bearer: TOKEN)
    assert_equal 401, status
  end

  # --- 202 response shape ----------------------------------------------------------

  def test_ingest_returns_202_with_id_session_id_status_events
    with_token_settings do
    status, headers, body = post_ingest(MINIMAL_JSONL, bearer: TOKEN)
    assert_equal 202, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert data.key?("id")
    assert_equal "minimal", data["session_id"]
    assert_equal "live", data["status"]
    assert_equal 1, data["events"]
    end
  end

  def test_zero_recognized_events_fail_visibly
    with_token_settings do
      status, _, body = post_ingest("", bearer: TOKEN)
      assert_equal 202, status
      data = parse_json(body)
      assert_equal 0, data["events"]
      assert_equal "failed", data["status"]
      assert_equal "Stream contained no recognizable events.", data["error"]
    end
  end

  def test_garbage_first_record_fails_with_error_passthrough
    with_token_settings do
      status, _, body = post_ingest("{\"type\":\"not-a-session\"}\n", bearer: TOKEN)
      assert_equal 202, status
      data = parse_json(body)
      assert_equal "failed", data["status"]
      assert data["error"].include?("session record")
    end
  end

  # --- idempotency end-to-end --------------------------------------------------------

  def test_whole_file_resend_lands_zero_duplicates
    with_token_settings do
      _, _, body1 = post_ingest(FIXTURE_JSONL, bearer: TOKEN)
      first = parse_json(body1)
      _, _, body2 = post_ingest(FIXTURE_JSONL, bearer: TOKEN)
      second = parse_json(body2)

      assert_equal first["id"], second["id"], "same conversation id"
      assert_equal 0, second["events"], "zero new events"

      msgs = @messages_repo.for_conversation(first["id"])
      assert_equal 4, msgs.length, "no duplicate messages"

      conv = @conversations_repo.by_pk(first["id"])
      assert_equal 1, @conversations_repo.by_user(@owner.id).length, "no duplicate conversation"
      assert_equal 4, conv.turns_count
    end
  end

  def test_chunked_appends_extend_the_conversation
    with_token_settings do
      _, _, body1 = post_ingest(MINIMAL_JSONL, bearer: TOKEN)
      conv_id = parse_json(body1)["id"]

      chunk2 = MINIMAL_JSONL + "{\"type\":\"message_end\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"chunk two\"}]}}\n"
      status, _, body2 = post_ingest(chunk2, bearer: TOKEN)
      assert_equal 202, status
      assert_equal 5, parse_json(body2)["events"]
      assert_equal conv_id, parse_json(body2)["id"]

      assert_equal 1, @messages_repo.for_conversation(conv_id).length
    end
  end

  # --- headers: parent linkage, space slug, agent metadata -----------------------------

  def test_parent_session_id_header_links_parent
    with_token_settings do
      _, _, body1 = post_ingest(SPACE_FIXTURE_JSONL, bearer: TOKEN)
      parent = parse_json(body1)

      status, _, body2 = post_ingest(CHILD_FIXTURE_JSONL, bearer: TOKEN,
                                     headers: { "X-Parent-Session-Id" => parent["session_id"] })
      assert_equal 202, status
      child = @conversations_repo.by_pk(parse_json(body2)["id"])
      assert_equal parent["session_id"], child.parent_session_id

      parent_conv = @conversations_repo.by_pk(parent["id"])
      assert_equal [child.id], @conversations_repo.children_of(parent_conv).map(&:id)
      assert_equal parent_conv.id, @conversations_repo.parent_of(child)&.id
    end
  end

  def test_space_slug_find_or_creates_space_and_links
    with_token_settings do
      status, _, body = post_ingest(SPACE_FIXTURE_JSONL, bearer: TOKEN,
                                    headers: { "X-Space-Slug" => "all-fax-no-printer" })
      assert_equal 202, status
      conv = @conversations_repo.by_pk(parse_json(body)["id"])
      space = Space::Server::App["repos.spaces_repo"].by_pk(conv.space_id)
      assert_equal "all-fax-no-printer", space.slug
      assert_equal @owner.id, space.user_id
      assert_equal "all-fax-no-printer", space.title, "title defaults to slug"

      # Second POST with the same slug reuses the space (find-or-create).
      post_ingest(CHILD_FIXTURE_JSONL, bearer: TOKEN, headers: { "X-Space-Slug" => "all-fax-no-printer" })
      assert_equal 1, Space::Server::App["repos.spaces_repo"].list_visible_to(@owner).length
    end
  end

  def test_absent_space_slug_leaves_space_id_null
    with_token_settings do
      _, _, body = post_ingest(SPACE_FIXTURE_JSONL, bearer: TOKEN)
      conv = @conversations_repo.by_pk(parse_json(body)["id"])
      assert_nil conv.space_id
      assert_equal "/Users/eric/architect/spaces/20261014-all-fax-no-printer", conv.original_cwd
    end
  end

  def test_agent_role_and_name_headers_materialize
    with_token_settings do
      _, _, body = post_ingest(MINIMAL_JSONL, bearer: TOKEN,
                               headers: { "X-Agent-Role" => "builder", "X-Agent-Name" => "mouth-lane" })
      conv = @conversations_repo.by_pk(parse_json(body)["id"])
      assert_equal "builder",   conv.agent_role
      assert_equal "mouth-lane", conv.agent_name
    end
  end

  # --- terminal header -------------------------------------------------------------------

  def test_terminal_header_completes_and_fans_out_terminal_event
    with_token_settings do
      status, _, body = post_ingest(MINIMAL_JSONL, bearer: TOKEN,
                                    headers: { "X-Session-Complete" => "true" })
      assert_equal 202, status
      data = parse_json(body)
      assert_equal "completed", data["status"]

      conv = @conversations_repo.by_pk(data["id"])
      assert_equal :completed, conv.status

      Sync do
        client = Async::Redis::Client.new(redis_endpoint)
        entries = client.xrange(Space::Server::Conversations::StreamKey.for(conv.id), "-", "+")
        assert_equal "conversation_complete", entries.last[1][1]
        client.close
      end
    end
  end

  def test_absent_terminal_header_stays_live
    with_token_settings do
      _, _, body = post_ingest(MINIMAL_JSONL, bearer: TOKEN)
      conv = @conversations_repo.by_pk(parse_json(body)["id"])
      assert_equal :live, conv.status
    end
  end

  # --- full fidelity + NUL ----------------------------------------------------------------

  def test_full_fidelity_blocks_persist
    with_token_settings do
      _, _, body = post_ingest(FIXTURE_JSONL, bearer: TOKEN)
      conv_id = parse_json(body)["id"]
      msgs = @messages_repo.for_conversation(conv_id)

      assert msgs[0].content.any? { |b| b["type"] == "text" }, "user prompt text"
      thinking = msgs[1].content.find { |b| b["type"] == "thinking" }
      assert_equal "I'll write a smoke test for the importer next.", thinking["thinking"], "thinking preserved"
      tool_use = msgs[1].content.find { |b| b["type"] == "tool_use" }
      assert_equal "read", tool_use["name"]
      assert_equal({ "file_path" => "/tmp/pi-stream-project/test/services/pi_importer_test.rb" }, tool_use["input"], "tool_use args preserved")
      tool_result = msgs[2].content.first
      assert_equal "tool_result", tool_result["type"]
      assert_equal "require \"test_helper\"", tool_result["content"]
    end
  end

  def test_nul_fixture_ingests_with_scrubbed_content
    with_token_settings do
      status, _, body = post_ingest(NUL_FIXTURE_JSONL, bearer: TOKEN)
      assert_equal 202, status
      msgs = @messages_repo.for_conversation(parse_json(body)["id"])
      tool_result = msgs.flat_map(&:content).find { |b| b["type"] == "tool_result" }
      assert_includes tool_result["content"], "Terminates the service"
      refute tool_result["content"].include?("\u0000"), "NUL bytes scrubbed from persisted content"
    end
  end

  # --- CSRF exemption (direct, mirroring omniauth_request_csrf_test.rb) -------------------

  def make_post_request(bearer: nil)
    env = Rack::MockRequest.env_for("/conversations/ingest", "REQUEST_METHOD" => "POST")
    env["rack.session"] = {}
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    Hanami::Action::Request.new(env: env, params: {})
  end

  def test_csrf_exempt_for_bearer_post_on_the_mouth
    action = Space::Server::Actions::Conversations::Ingest.new
    req = make_post_request(bearer: "any-bearer")
    refute action.send(:verify_csrf_token?, req, nil),
      "bearer POST must be CSRF-exempt (bearer presence, not validity)"
  end

  def test_csrf_required_for_cookie_post_on_the_mouth
    action = Space::Server::Actions::Conversations::Ingest.new
    req = make_post_request
    assert action.send(:verify_csrf_token?, req, nil),
      "cookie/session POST must have CSRF enforcement active"
  end

  private

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end
end
