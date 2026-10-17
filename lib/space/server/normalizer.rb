# frozen_string_literal: true

require_relative "normalizer/event"
require_relative "normalizer/pi"

module Space
  module Server
    module Normalizer
      # Detect the producer given a pre-parsed first-line record; returns the parser
      # class, or nil when no parser claims the stream. Pure classification — no I/O,
      # no instantiation.
      #
      # pi is the only parser this iteration keeps: its --mode json first line is
      # {"type":"session",...,"version":N,...} — no session_id/sessionId/sessionID/
      # part key, so "version" is the clean tell. There is no fallback parser: a
      # non-pi first line leaves select at nil, Conversations::Ingest's `Normalizer.select(
      # record).new` raises, and the ingest rescue path fails visibly — the same
      # visible failure the I05 zero-event rule mandates for unrecognizable streams.
      def self.select(record)
        return Pi if record["type"] == "session" && record.key?("version")
        nil
      end
    end
  end
end