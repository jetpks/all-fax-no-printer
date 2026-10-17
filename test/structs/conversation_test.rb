# frozen_string_literal: true

require_relative "../test_helper"

# G1 (crux): Conversation struct predicate tests — the published/owned/snippet
# visibility scenarios. Structs are loaded via conversations_repo.with_messages
# so the :messages association is combined (required by the predicates).
# Users are loaded via users_repo so Space::Server::Structs::User (with org_ids) is used.
class ConversationStructTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:messages, :conversations, :users].each { |t| conn[t].delete }

    @repo       = Space::Server::App["repos.conversations_repo"]
    @users_repo = Space::Server::App["repos.users_repo"]
    @msg_repo   = Space::Server::App["repos.messages_repo"]

    @owner    = load_user(Factory[:user, github_uid: "1",  username: "owner"])
    @stranger = load_user(Factory[:user, github_uid: "2",  username: "stranger"])

    @conv  = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1  = Factory[:message, conversation_id: @conv.id, role: "user",
                     content: [{ "type" => "text", "text" => "go" }],
                     position: 0, published: false]
    @msg2  = Factory[:message, conversation_id: @conv.id, role: "assistant",
                     content: [{ "type" => "text", "text" => "done" }],
                     position: 1, published: false]
  end

  def load_user(u)
    @users_repo.by_pk(u.id)
  end

  def load
    @repo.with_messages(@conv.id)
  end

  # 1. Private — invisible to anyone but the owner
  def test_private_conversation_invisible_to_non_owner
    conv = load
    refute conv.visible_to?(nil),        "nil (anon) must not see private conv"
    refute conv.visible_to?(@stranger),  "stranger must not see private conv"
    assert conv.visible_to?(@owner),     "owner must see own conv"
  end

  # 2. Non-owner with a published snippet sees only published messages
  def test_snippet_visibility_shows_published_messages_only_to_non_owner
    @msg_repo.update(@msg1.id, published: true, updated_at: Time.now)
    conv = load

    assert conv.visible_to?(@stranger),     "published snippet makes conv visible"
    assert_equal [@msg1.id],
                 conv.visible_messages(@stranger).map(&:id),
                 "non-owner must only receive published messages"
  end

  # 3. Published — visible to all, full transcript for everyone
  def test_published_conv_visible_to_all_with_full_transcript
    @repo.update(@conv.id, published: true, updated_at: Time.now)
    conv = load

    assert conv.visible_to?(nil),        "published conv visible to anon"
    assert conv.visible_to?(@stranger),  "published conv visible to stranger"
    assert_equal [@msg1.id, @msg2.id],
                 conv.visible_messages(@stranger).map(&:id),
                 "published conv shows all messages to anyone"
  end
end