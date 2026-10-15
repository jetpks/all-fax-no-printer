# frozen_string_literal: true

require "securerandom"
require "digest"

module Space
  module Server
    module Repos
      # Per-user machine-auth tokens. Secret hygiene: the plaintext secret
      # exists exactly once — returned by create at mint time — and only its
      # SHA-256 hex digest is ever persisted. Lookup is a unique-index hit on
      # token_hash, never a linear scan or plaintext comparison.
      class APITokensRepo < Space::Server::DB::Repo
        # Mints a new token for the user and persists only its hash.
        # Returns [secret, token] — the secret for the single render-at-mint,
        # the persisted row (token_hash only) for everything else.
        def create(user_id:, name:)
          secret = "sat_#{SecureRandom.hex(32)}"
          token = api_tokens.command(:create).call(
            user_id:    user_id,
            name:       name,
            token_hash: hash_secret(secret),
            created_at: Time.now
          )
          [secret, token]
        end

        # Unique-index lookup of an unrevoked token by SHA-256 hex digest of
        # the presented bearer. Nil when unknown or revoked — no distinction.
        def find_active_by_hash(token_hash)
          api_tokens.where(token_hash: token_hash, revoked_at: nil).one
        end

        def touch_last_used(id)
          api_tokens.where(id: id).command(:update).call(last_used_at: Time.now)
        end

        # Soft revoke — the row survives so mint history stays auditable; a
        # revoked token's hash can never authenticate again.
        def revoke(id)
          api_tokens.where(id: id, revoked_at: nil).command(:update).call(revoked_at: Time.now)
        end

        def list_by_user(user_id)
          api_tokens.where(user_id: user_id).order(Sequel.desc(:created_at)).to_a
        end

        def by_pk(id)
          api_tokens.by_pk(id).one
        end

        private

        def hash_secret(secret)
          Digest::SHA256.hexdigest(secret)
        end
      end
    end
  end
end
