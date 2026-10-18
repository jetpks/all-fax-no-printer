# frozen_string_literal: true

require "hanami"
require "hanami_credentials"
require "hanami_healthcheck"
require "hanami_force_ssl"
require "rack/protection/host_authorization"
require "omniauth"
require "omniauth-github"
require "inertia_hanami"
require "vite_hanami"

module Space
  module Server
    # 30 days, in seconds. Phone-first deck (BRIEF §1): iOS Safari discards a
    # backgrounded tab's browser-session cookies, which bounced the phone out
    # hourly. rack-session re-dates the expiry on every committing response,
    # so the window slides with use.
    SESSION_EXPIRE_AFTER = 2_592_000

    class App < Hanami::App
      config.settings_store = HanamiCredentials::Store.new(
        content_path: Pathname(__dir__).join("credentials.yml.enc"),
        env_key: "SPACE_SERVER_MASTER_KEY",
        key_path: Pathname(__dir__).join("master.key")
      )

      # SQL query logging at :info. Hanami 3 defaults config.db.log_level to
      # :debug, which would dump every SQL statement to the production log;
      # :info preserves the 2.x-era log volume.
      config.db.log_level = :info

      # Redirect 127.0.0.1 → localhost (Vite dev server uses localhost; this keeps
      # the browser and Vite on the same origin so HMR works). Port via Rack
      # middleware since hanami-router 2.3.1 has no host-constraint DSL.
      HostRedirect = Class.new do
        def initialize(app) = @app = app

        def call(env)
          return @app.call(env) unless (env["HTTP_HOST"] || "").start_with?("127.0.0.1")

          loc = "#{env['rack.url_scheme'] || 'http'}://localhost:#{env['SERVER_PORT']}#{env['PATH_INFO']}"
          loc = "#{loc}?#{env['QUERY_STRING']}" unless env["QUERY_STRING"].to_s.empty?
          [301, {"location" => loc, "content-length" => "0", "content-type" => "text/plain"}, []]
        end
      end

      # Guards the raw-body ingest route against the router/body-parser stack
      # touching rack.input before the ingest actions read it. hanami-router
      # 3.0.0's _form_urlencoded_body (lib/hanami/router.rb:1061) and
      # Middleware::BodyParser#call (lib/hanami/middleware/body_parser.rb:37)
      # both short-circuit when ROUTER_PARSED_BODY is present — so setting it
      # here keeps the ingest stream untouched for incremental reads/streaming,
      # by construction rather than by content-type.
      IngestBodyPassthrough = Class.new do
        RAW_BODY_ROUTES = %r{\A/conversations/ingest\z}

        def initialize(app) = @app = app

        def call(env)
          if env["REQUEST_METHOD"] == "POST" && RAW_BODY_ROUTES.match?(env["PATH_INFO"])
            env[Hanami::Router::ROUTER_PARSED_BODY] ||= {}
          end
          @app.call(env)
        end
      end

      config.actions.sessions = :cookie, {
        key: "_space_server_session",
        secret: settings.session_secret,
        # Secure whenever the app is behind TLS (assume_ssl: Caddy terminates and
        # proxies plain HTTP; force_ssl: app redirects to https). Off in plain-http
        # dev so the cookie still rides. same_site :lax keeps the OAuth callback
        # (a top-level GET from github.com) carrying the session while blocking
        # cross-site POST — matches the XSRF-TOKEN cookie's own lax posture.
        secure: settings.assume_ssl || settings.force_ssl,
        same_site: :lax,
        expire_after: SESSION_EXPIRE_AFTER
      }
      # csrf_protection defaults to true when sessions are enabled;
      # hanami-action auto-disables it in HANAMI_ENV=test

      # OmniAuth GitHub OAuth — on_failure routes to our failure action via redirect.
      # Captured here so the block below closes over resolved values (not the lazy setting).
      _github_id     = settings.github_client_id
      _github_secret = settings.github_client_secret

      OmniAuth.config.on_failure = proc do |env|
        msg = Rack::Utils.escape(env["omniauth.error.type"]&.to_s || "unknown")
        [302, {"location" => "/auth/failure?message=#{msg}", "content-type" => "text/html", "content-length" => "0"}, []]
      end

      # Request-phase CSRF for OmniAuth. The SPA sign-in form (Nav.tsx) submits Hanami's own
      # `_csrf_token` (read from the XSRF-TOKEN cookie) as `authenticity_token`. Validate the
      # request phase against THAT session token — one CSRF token shared by Hanami actions and
      # OmniAuth — mirroring the Rails oracle's single token (omniauth-rails_csrf_protection).
      # (Replaces OmniAuth's default rack-protection AuthenticityToken, which checks a separate
      # `:csrf` session key the frontend never sends.) Raises AuthenticityError → on_failure.
      OmniAuth.config.request_validation_phase = lambda do |env|
        session = env["rack.session"] || {}
        expected = (session[:_csrf_token] || session["_csrf_token"]).to_s
        submitted = (Rack::Request.new(env).params["authenticity_token"] || env["HTTP_X_CSRF_TOKEN"]).to_s

        unless !expected.empty? && !submitted.empty? && Rack::Utils.secure_compare(expected, submitted)
          raise OmniAuth::AuthenticityError, "invalid authenticity token"
        end
      end

      config.middleware.use OmniAuth::Builder do
        provider :github, _github_id, _github_secret,
          scope: "read:user,user:email,read:org"
      end

      # OmniAuth's request phase 302-redirects the sign-in POST to github.com, and the
      # CSP `form-action` directive is enforced across the whole redirect chain — so the
      # provider origin must be allow-listed (every env; the redirect happens in prod too).
      # Chrome reports the violation against the pre-redirect /auth/github URL, which is
      # why it misreads as a 'self' block.
      config.actions.content_security_policy[:form_action] += " https://github.com"

      config.middleware.use HostRedirect
      config.middleware.use IngestBodyPassthrough

      # JSON request bodies. Hanami 3 ships NO implicit body parser — the
      # app config has no use_body_parser_middleware auto-append anymore, so
      # without this line JSON bodies would never reach req.params. The symbol
      # resolves at use-time to Hanami::Middleware::BodyParser (shipped by
      # hanami-router, lib/hanami/middleware/body_parser.rb; the middleware
      # stack's load_middleware_class requires it and classifies the symbol).
      # Registered explicitly so the JSON contract is legible here, and so its
      # position relative to IngestBodyPassthrough is pinned rather than
      # incidental. Placed AFTER IngestBodyPassthrough: that middleware pre-sets
      # ROUTER_PARSED_BODY ("router.parsed_body") for /conversations/ingest, and
      # BodyParser's own `call` short-circuits whenever that key is already
      # present (hanami-router 3.0.0 body_parser.rb:37) — so the ingest stream is
      # skipped by construction, not by content-type (application/x-ndjson) alone.
      config.middleware.use :body_parser, :json

      # Dev-only: the Vite dev server (port 3036) serves ES modules cross-origin and injects an
      # inline React-refresh preamble — both blocked by the default `script-src 'self'` CSP, which
      # renders a blank page. Relax script/connect/style to the dev server (+ inline/eval for HMR)
      # in development only; production keeps Hanami's strict default CSP.
      if Hanami.env?(:development)
        vite = "http://localhost:3036"
        csp = config.actions.content_security_policy
        csp[:script_src]  += " 'unsafe-inline' 'unsafe-eval' #{vite}"
        csp[:connect_src] += " #{vite} ws://localhost:3036"
        csp[:style_src]   += " #{vite}"
        csp[:font_src]    += " #{vite}"
      end

      # Dev-only: proxy /vite-dev/ asset paths to the Vite dev server before the app handles them.
      config.middleware.use ViteHanami::DevServerProxy if Hanami.env?(:development)

      # Inertia protocol: 409 stale-reload, 303 coercion, errors cleanup, XSRF→CSRF bridge.
      # Must be inside Rack::Session::Cookie (slice.rb:1088 > 1075); added last so it wraps
      # the router/actions innermost.
      config.middleware.use InertiaHanami::Middleware
    end
  end
end
