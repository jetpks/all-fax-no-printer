# frozen_string_literal: true

module Space
  module Server
    module Conversations
      module StreamKey
        TTL_SECONDS = 1800  # 30 minutes

        def self.for(conversation_id)
          "conversation:#{conversation_id}"
        end
      end
    end
  end
end
