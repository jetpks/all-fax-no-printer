# frozen_string_literal: true

module Space
  module Server
    module Structs
      # The visibility predicates require :messages combined — accessed via
      # conversations_repo.with_messages(id) or for_show(id). ROM raises loudly if the
      # messages association is accessed un-combined; that is the intentional safe
      # failure mode.
      class Conversation < ::Space::Server::DB::Struct
        def pending?    = status == :pending
        def live?       = status == :live
        def completed?  = status == :completed
        def failed?     = status == :failed

        def published?
          !!published
        end

        def owned_by?(user)
          !user.nil? && user.id == user_id
        end

        # Whole-conversation visibility: published, owned, or has a published snippet.
        def visible_to?(user)
          published? ||
            owned_by?(user) ||
            messages.any?(&:published)
        end

        # Owners and viewers of a published conversation see all messages; others
        # only see individually-published messages.
        def visible_messages(viewer)
          return messages if published? || owned_by?(viewer)
          messages.select(&:published)
        end
      end
    end
  end
end
