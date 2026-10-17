# frozen_string_literal: true

require_relative "../test_helper"

class ConversationsRepoTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    [:artifacts, :iterations, :messages, :conversations, :spaces, :users].each { |t| conn[t].delete }
  end

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def users_repo = Space::Server::Repos::UsersRepo.new

  # Reloaded through UsersRepo so callers get the auto_struct-mapped
  # Structs::User (with #org_ids), rather than the bare struct ROM::Factory
  # hands back.
  def make_user(overrides = {})
    users_repo.by_pk(Factory[:user, **overrides].id)
  end

  # --- visible_to (I45 pagination) ----------------------------------------

  def test_visible_to_defaults_to_page_1_capped_at_page_size
    user = make_user
    55.times { Factory[:conversation, user_id: user.id, published: true] }
    result = conversations_repo.visible_to(user)
    assert_equal 50, result[:rows].length
    assert result[:has_more]
  end

  def test_visible_to_page_2_returns_remaining_rows_and_has_more_false
    user = make_user
    55.times { |i| Factory[:conversation, user_id: user.id, published: true, updated_at: Time.now - i] }
    result = conversations_repo.visible_to(user, page: 2)
    assert_equal 5, result[:rows].length
    refute result[:has_more]
  end

  def test_visible_to_orders_by_updated_at_desc
    user = make_user
    older = Factory[:conversation, user_id: user.id, published: true,
                     updated_at: Time.now - 3600, created_at: Time.now - 7200]
    newer = Factory[:conversation, user_id: user.id, published: true,
                     updated_at: Time.now, created_at: Time.now - 100]
    result = conversations_repo.visible_to(user)
    assert_equal [newer.id, older.id], result[:rows].map(&:id)
  end

  def test_visible_to_anonymous_sees_published_only
    user = make_user
    published = Factory[:conversation, user_id: user.id, published: true]
    Factory[:conversation, user_id: user.id, published: false]
    result = conversations_repo.visible_to(nil)
    assert_equal [published.id], result[:rows].map(&:id)
  end

  # Recording logger stand-in — Sequel::Database#loggers accepts anything
  # responding to the Logger interface; #info is what Sequel calls per query.
  class SqlSpy
    attr_reader :statements
    def initialize = @statements = []
    def info(msg) = @statements << msg
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  # I36 discipline must hold under pagination too: visible_to never combines
  # :messages, at any page.
  def test_visible_to_issues_no_message_queries_while_paging
    user = make_user
    55.times { |i| Factory[:conversation, user_id: user.id, published: true, updated_at: Time.now - i] }
    conv = Factory[:conversation, user_id: user.id, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    spy = SqlSpy.new
    conn.loggers << spy
    conversations_repo.visible_to(user, page: 2)
    conn.loggers.delete(spy)

    message_queries = spy.statements.select { |sql| sql.include?(%(FROM "messages")) }
    assert_equal 0, message_queries.length,
      "expected zero queries against messages, got #{message_queries.length}"
  end

  # ── space filters + unspaced bucketing (I08) ─────────────────────────────────

  def test_visible_to_space_id_filter_narrows_scope
    user = make_user
    in_space  = Factory[:conversation, user_id: user.id, published: true, space_id: 7]
    elsewhere = Factory[:conversation, user_id: user.id, published: true, space_id: 9]

    result = conversations_repo.visible_to(user, space_id: 7)
    assert_equal [in_space.id], result[:rows].map(&:id)
  end

  def test_visible_to_cwd_filter_narrows_scope
    user = make_user
    mine   = Factory[:conversation, user_id: user.id, published: true, original_cwd: "/a"]
    _other = Factory[:conversation, user_id: user.id, published: true, original_cwd: "/b"]

    result = conversations_repo.visible_to(user, cwd: "/a")
    assert_equal [mine.id], result[:rows].map(&:id)
  end

  def test_for_space_returns_space_conversations_newest_updated_first
    user = make_user
    older = Factory[:conversation, user_id: user.id, space_id: 7, updated_at: Time.now - 3600]
    newer = Factory[:conversation, user_id: user.id, space_id: 7, updated_at: Time.now]
    Factory[:conversation, user_id: user.id, space_id: 9]

    assert_equal [newer.id, older.id], conversations_repo.for_space(7).map(&:id)
  end

  def test_unspaced_cwd_buckets_groups_null_space_conversations
    user = make_user
    Factory[:conversation, user_id: user.id, published: false, space_id: nil,
            original_cwd: "/p1", updated_at: Time.now - 60]
    Factory[:conversation, user_id: user.id, published: false, space_id: nil,
            original_cwd: "/p1", updated_at: Time.now]
    Factory[:conversation, user_id: user.id, published: false, space_id: nil,
            original_cwd: "/p2"]
    Factory[:conversation, user_id: user.id, published: false, space_id: nil, original_cwd: nil]
    Factory[:conversation, user_id: user.id, published: false, space_id: 7, original_cwd: "/spaced"]

    buckets = conversations_repo.unspaced_cwd_buckets(user).to_h { |b| [b[:original_cwd], b] }
    assert_equal 2, buckets["/p1"][:conversations_count]
    assert_equal 1, buckets["/p2"][:conversations_count]
    refute buckets.key?("/spaced"), "spaced conversations never land in unspaced buckets"
    last_activity = buckets["/p1"][:last_activity_at]
    assert_operator last_activity, :<=, Time.now
    assert_operator last_activity, :>=, Time.now - 2, "last_activity_at = max updated_at in the bucket"
  end

  def test_unspaced_cwd_buckets_scope_is_visible_to
    user = make_user
    Factory[:conversation, user_id: user.id, published: false, space_id: nil, original_cwd: "/mine"]
    Factory[:conversation, user_id: user.id, published: true,  space_id: nil, original_cwd: "/published"]

    assert_equal %w[/published], conversations_repo.unspaced_cwd_buckets(nil).map { |b| b[:original_cwd] }
    assert_equal %w[/mine /published].sort,
      conversations_repo.unspaced_cwd_buckets(user).map { |b| b[:original_cwd] }.sort
  end
end
