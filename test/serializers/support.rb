# frozen_string_literal: true

# Minimal support for serializer unit tests.
# Does NOT require hanami/prepare — no DB, no app boot needed.
$LOAD_PATH.unshift File.expand_path("../../app", __dir__)

require "minitest/autorun"
require "serializers/conversation"

# Duck-typed plain-Ruby fixtures — the serializer only calls methods, never
# inspects class identity, so these satisfy the duck-type contract fully.

TestUser = Data.define(:id, :username, :name, :avatar_url)

TestMsg = Data.define(:id, :role, :model, :position, :published, :blocks)

TestRound = Data.define(:anchor_id, :messages)

TestTurn = Data.define(:anchor_id, :prompt, :rounds)

TestConversation = Data.define(
  :id, :title, :status, :published, :source, :original_cwd, :git_branch,
  :agent_version, :user, :owner_id
) do
  def owned_by?(viewer)
    viewer&.id == owner_id
  end
end