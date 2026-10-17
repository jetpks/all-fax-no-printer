# frozen_string_literal: true

module Space
  module Server
    module Relations
      class Conversations < Space::Server::DB::Relation
        STATUS_MAP    = { 0 => :pending, 1 => :live, 2 => :completed, 3 => :failed }.freeze
        STATUS_TO_INT = STATUS_MAP.invert.freeze
        STATUS_READ   = ROM::Types::Symbol.constructor { |v| STATUS_MAP.fetch(v.to_i) }

        schema(:conversations, infer: true) do
          attribute :status, ROM::SQL::Types::Integer, read: STATUS_READ

          associations do
            belongs_to :user
            belongs_to :space
            has_many :messages, view: :ordered_by_position
          end
        end
      end
    end
  end
end
