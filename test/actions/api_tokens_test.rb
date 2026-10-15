# frozen_string_literal: true

require_relative "action_test_helper"

class ApiTokensTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:api_tokens].delete
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "api-tokens-owner", username: "api-tokens-owner"]
    @other = Factory[:user, github_uid: "api-tokens-other", username: "api-tokens-other"]
    @repo  = Space::Server::App["repos.api_tokens_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def mint(user, name = "cli")
    @repo.create(user_id: user.id, name: name)[1]
  end

  # --- GET /api_tokens — session required, own tokens only -------------------

  def test_index_anon_redirects_with_flash
    status, headers, _ = get("/api_tokens")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_index_lists_own_tokens_only
    mint(@owner, "alpha")
    mint(@other, "foreign")
    sign_in(@owner)
    status, _, body = inertia_get("/api_tokens")
    assert_equal 200, status
    names = parse_json(body).dig("props", "tokens").map { |t| t["name"] }
    assert_equal %w[alpha], names
  end

  def test_index_token_shape
    mint(@owner)
    sign_in(@owner)
    _, _, body = inertia_get("/api_tokens")
    entry = parse_json(body).dig("props", "tokens").first
    assert entry.key?("id")
    assert entry.key?("name")
    assert entry.key?("created_at")
    assert entry.key?("last_used_at")
    assert entry.key?("revoked_at")
    refute entry.key?("token_hash")
  end

  # --- POST /api_tokens — mint renders the secret exactly once ---------------

  def test_create_anon_redirects_with_flash
    status, headers, _ = post("/api_tokens", params: { name: "cli" })
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_create_persists_hash_only_and_renders_secret_once
    sign_in(@owner)
    status, _, body = inertia_post("/api_tokens", params: { name: "cli" })
    assert_equal 200, status

    tokens = @repo.list_by_user(@owner.id)
    assert_equal 1, tokens.size
    row = tokens.first
    assert_equal "cli", row.name
    assert_match(/\A[0-9a-f]{64}\z/, row.token_hash, "only the SHA-256 hex digest is persisted")
    assert_nil row.revoked_at

    secret = parse_json(body).dig("props", "minted", "secret")
    assert_match(/\Asat_[0-9a-f]{64}\z/, secret)
    rendered = body.respond_to?(:join) ? body.join : body.to_s
    assert_equal 1, rendered.scan(secret).count, "the plaintext secret renders exactly once"
    assert_equal Digest::SHA256.hexdigest(secret), row.token_hash
    refute rendered.include?(row.token_hash), "the hash is not echoed back to the browser"
  end

  def test_create_missing_name_redirects_with_field_error
    sign_in(@owner)
    status, headers, _ = post("/api_tokens", params: { name: "" })
    assert_equal 302, status
    assert_equal "/api_tokens/new", headers["location"]
    errors = flash_errors(headers)
    assert errors["name"]
  end

  def flash_errors(headers)
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/api_tokens/new", cookie: redirect_cookie)
    parse_json(body).dig("props", "errors")
  end

  # Inertia XHR POST — same header set inertia_get sends, so Create's once-only
  # mint render comes back as the JSON page object.
  def inertia_post(path, params: {})
    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      input: URI.encode_www_form(params)
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = Space::Server::App["vite"].digest
    app.call(env)
  end

  # --- POST /api_tokens/:id/delete — soft revoke ------------------------------

  def test_destroy_anon_redirects_with_flash
    token = mint(@owner)
    status, headers, _ = post("/api_tokens/#{token.id}/delete")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_destroy_revokes_softly
    token = mint(@owner)
    sign_in(@owner)
    status, headers, _ = post("/api_tokens/#{token.id}/delete")
    assert_equal 302, status
    assert_equal "/api_tokens", headers["location"]

    row = @repo.by_pk(token.id)
    refute_nil row, "revoke must be soft — the row survives"
    refute_nil row.revoked_at
    flash = flash_from_redirect(headers, cookie: headers["set-cookie"]&.split(";")&.first)
    assert_equal "Token revoked.", flash["notice"]
  end

  def test_destroy_foreign_token_halts_404
    token = mint(@other)
    sign_in(@owner)
    status, _, body = post("/api_tokens/#{token.id}/delete")
    assert_equal 404, status
    assert parse_json(body).key?("error")
    assert_nil @repo.by_pk(token.id).revoked_at
  end
end
