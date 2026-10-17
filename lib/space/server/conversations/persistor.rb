# frozen_string_literal: true

require "json"
require_relative "../nul_scrub"

module Space
  module Server
    module Conversations
      # Consumes normalized events and incrementally persists messages onto a
      # conversation. Blocks are accumulated in memory; a DB write happens on
      # each message_complete (or tool_result).
      #
      # Usage:
      #   persistor = Persistor.new(conversations_repo, messages_repo)
      #   persistor.setup(conversation)  # binds to the conversation, returns it
      #   events.each { persistor.process(_1) }
      #   persistor.conversation_id      # the bound conversation
      class Persistor
        TITLE_MAX_LENGTH = 80

        attr_reader :conversation_id, :first_model

        def initialize(conversations_repo, messages_repo)
          @conversations_repo = conversations_repo
          @messages_repo      = messages_repo
          reset!
        end

        # Binds to an existing conversation (created or found by the ingest
        # mouth's find-or-create). Must be called before process. Message
        # positions continue from the conversation's existing message count,
        # so append chunks land in order across POSTs.
        def setup(conversation)
          @conversation_id = conversation.id
          @title           = conversation.title
          @model           = conversation.model
          @position        = conversation.turns_count.to_i
          conversation
        end

        def process(event)
          case event[:type]
          when :message_start    then start_message(event)
          when :block_open       then open_block(event)
          when :text_delta       then append_text(event)
          when :tool_args_delta  then append_tool_args(event)
          when :block_close      then close_block(event)
          when :message_complete then flush_message
          when :tool_result      then write_tool_result(event)
          end
        end

        private

        def reset!
          @conversation_id = nil
          @position        = 0
          @current_msg     = nil
          @first_model     = nil
          @title           = nil
          @model           = nil
        end

        def start_message(event)
          @current_msg = { role: event[:role] || "assistant", model: event[:model], blocks: {}, ordered: [] }
        end

        def open_block(event)
          return unless @current_msg
          block = case event[:block_type]
                  when :text
                    { "type" => "text", "text" => "" }
                  when :thinking
                    { "type" => "thinking", "thinking" => "" }
                  when :tool_use
                    { "type" => "tool_use", "name" => event[:name], "id" => event[:tool_use_id], "input" => "" }
                  else
                    { "type" => event[:block_type].to_s }
                  end
          @current_msg[:blocks][event[:block_id]] = block
          @current_msg[:ordered] << block
        end

        def append_text(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block
          case block["type"]
          when "text"     then block["text"]     = block["text"].to_s     + event[:text].to_s
          when "thinking" then block["thinking"] = block["thinking"].to_s + event[:text].to_s
          end
        end

        def append_tool_args(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block && block["type"] == "tool_use"
          block["input"] = block["input"].to_s + event[:partial_json].to_s
        end

        def close_block(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block && block["type"] == "tool_use"
          raw = block["input"].to_s
          block["input"] = raw.empty? ? {} : (JSON.parse(raw) rescue {})
        end

        def flush_message
          return unless @current_msg && @conversation_id
          if @first_model.nil? && @current_msg[:role] == "assistant" && @current_msg[:model]
            @first_model = @current_msg[:model]
          end
          @messages_repo.create(
            conversation_id: @conversation_id,
            role:            @current_msg[:role],
            model:           @current_msg[:model],
            content:         Space::Server::NulScrub.scrub_nul(@current_msg[:ordered]),
            position:        @position,
            published:       false,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
          materialize_metadata(@current_msg[:role])
          @current_msg = nil
        end

        def write_tool_result(event)
          return unless @conversation_id
          # In real streams, tool_result fires before message_complete for the same turn.
          # Flush the pending assistant message first so positions are ordered correctly.
          flush_message
          @messages_repo.create(
            conversation_id: @conversation_id,
            role:            "user",
            content:         Space::Server::NulScrub.scrub_nul(
                               [{ "type" => "tool_result", "tool_use_id" => event[:tool_use_id],
                                  "content" => event[:content], "is_error" => event[:is_error] }]
                             ),
            position:        @position,
            published:       false,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
          materialize_count
        end

        # Metadata lands on the conversation once, from the message that first
        # carries it: title from the first user message's leading text block
        # (≤ TITLE_MAX_LENGTH chars), model from the first assistant message.
        # turns_count is the running message count. Never overwrites. Called
        # from flush_message only — a tool_result row is not a turn-prompt and
        # its pending assistant message was already materialized by the flush.
        def materialize_metadata(role)
          materialize_count
          return unless @current_msg

          updates = {}
          if @title.nil? && role == "user"
            leading = leading_text_block
            updates[:title] = leading[0, TITLE_MAX_LENGTH] unless leading.empty?
          end
          updates[:model] = @first_model if @model.nil? && @first_model

          @conversations_repo.update(@conversation_id, updates) unless updates.empty?
          @title = updates[:title] if updates.key?(:title)
          @model = updates[:model] if updates.key?(:model)
        end

        # The first user message's leading text block's text (empty when the
        # message opens with anything else).
        def leading_text_block
          leading = Array(@current_msg[:ordered]).first
          return "" unless leading.is_a?(Hash) && leading["type"] == "text"
          leading["text"].to_s
        end

        def materialize_count
          @conversations_repo.update(@conversation_id, turns_count: @position, updated_at: Time.now)
        end
      end
    end
  end
end
