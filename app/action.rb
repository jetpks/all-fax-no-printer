# auto_register: false
# frozen_string_literal: true

require "hanami/action"
require "dry/monads"
require "json"
require "digest"
require "inertia_hanami"

module Space
  module Server
    class Action < Hanami::Action
      include Dry::Monads[:result]
      include InertiaHanami::Action
      include Space::Server::Deps["repos.users_repo", "repos.api_tokens_repo", "settings"]

      private

      JSON_CONTENT_TYPE = "application/json; charset=utf-8"

      # Session-only lookup. Takes req explicitly; safe when actions are singleton
      # objects (no per-request instance state).
      def current_user(req)
        return nil unless (uid = req.session[:user_id])
        users_repo.by_pk(uid)
      end

      # Bearer-token lookup, two paths:
      #   1. Per-user API tokens — the presented bearer is SHA-256 hashed and
      #      looked up on api_tokens.token_hash (unique index, revoked tokens
      #      excluded). A hit authenticates as the token's owner.
      #   2. Legacy global INGEST_TOKEN — byte-for-byte back-compat with the
      #      deployed CLI path: constant-time compare against settings, run
      #      attribution to settings.ingest_user_id.
      # A rejected bearer warns (path + outcome + hash shape only — never token
      # material) so failed machine pushes are visible in logs.
      # Nil/empty configured token can NEVER match — guarded explicitly before
      # secure_compare.
      def token_user(req)
        auth = req.env["HTTP_AUTHORIZATION"].to_s
        return nil unless auth.start_with?("Bearer ")

        bearer = auth[7..]
        user = api_token_user(bearer) || global_token_user(bearer)
        warn_rejected_bearer(req, bearer) unless user
        user
      end

      def authenticated_user(req)
        current_user(req) || token_user(req)
      end

      # --- Bearer auth paths (see token_user) --------------------------------

      # Per-user API token. Hash-lookup semantics: the digest either indexes a
      # row or it doesn't — no linear scan, no plaintext comparison. A hit
      # touches last_used_at so mint history shows real usage.
      def api_token_user(bearer)
        return nil if bearer.nil? || bearer.empty?

        token = api_tokens_repo.find_active_by_hash(Digest::SHA256.hexdigest(bearer))
        return nil unless token

        api_tokens_repo.touch_last_used(token.id)
        users_repo.by_pk(token.user_id)
      end

      # Legacy global INGEST_TOKEN — preserved byte-for-byte as the back-compat
      # fallback (deployed CLI setups keep working; IngestToken#resolve! has no
      # callers and hand-set env remains load-bearing).
      def global_token_user(bearer)
        token = settings.ingest_token
        return nil if token.nil? || token.empty?

        return nil unless ::Rack::Utils.secure_compare(token, bearer)

        uid = settings.ingest_user_id
        return nil if uid.nil?

        users_repo.by_pk(uid)
      end

      # Failure visibility (I02 silent-401 gap): log path + outcome + a hash
      # shape only. The bearer's material and anything re-identifying beyond
      # its digest prefix never enter the log.
      def warn_rejected_bearer(req, bearer)
        digest = Digest::SHA256.hexdigest(bearer.to_s)
        Hanami.logger.warn(
          "bearer auth rejected path=#{req.path} outcome=no_matching_token hash_prefix=#{digest[0, 12]}…"
        )
      end

      def render_json(res, data, status: 200)
        res.status = status
        res.content_type = JSON_CONTENT_TYPE
        res.body = JSON.generate(data)
      end

      # Set JSON content-type before halting so it survives the throw/catch.
      # Hanami::Action#finish sets res.status+body from the halted tuple but
      # does NOT reset content_type, so this assignment persists.
      def halt_not_found(res)
        res.content_type = JSON_CONTENT_TYPE
        halt 404, JSON.generate(error: "Not found")
      end

      def halt_unprocessable(res, errors)
        res.content_type = JSON_CONTENT_TYPE
        halt 422, JSON.generate(errors: errors)
      end

      # Redirect with a flash message. res.redirect_to calls Halt.call (throw :halt),
      # aborting handle — no separate halt needed after this call.
      def redirect_with_flash(res, to, notice: nil, alert: nil)
        res.flash["notice"] = notice if notice
        res.flash["alert"] = alert if alert
        res.redirect_to(to)
      end

      # redirect_back with flash: uses Referer or fallback URL.
      def bearer_request?(req)
        req.env["HTTP_AUTHORIZATION"].to_s.start_with?("Bearer ")
      end

      def redirect_back_with_flash(req, res, fallback:, notice: nil, alert: nil)
        to = req.env["HTTP_REFERER"].to_s
        to = fallback if to.empty?
        redirect_with_flash(res, to, notice: notice, alert: alert)
      end

      # Returns the current user or redirects to / with flash if anonymous.
      def require_login(req, res)
        user = current_user(req)
        redirect_with_flash(res, "/", alert: "Please sign in to continue.") unless user
        user
      end

      # Two-tier owner guard matching oracle behavior (require_login fires first for
      # owner-only actions in the oracle, then require_owner for non-owners).
      # Returns the current user, or redirects with flash and halts.
      def require_owner(req, res, conversation)
        user = current_user(req)
        unless user
          redirect_with_flash(res, "/", alert: "Please sign in to continue.")
        end
        unless conversation.owned_by?(user)
          redirect_with_flash(res, "/", alert: "Not authorized.")
        end
        user
      end
    end
  end
end
