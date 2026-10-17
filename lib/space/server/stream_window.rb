# frozen_string_literal: true

module Space
  module Server
    # Message-boundary windowing over Redis display-stream entries. Live
    # streams and history endpoints speak in MESSAGES, not raw entries: a
    # window opens at a "message_start" entry and holds everything after it,
    # so a client asking for the last N messages gets whole readable units
    # (a message's deltas and results stay with it).
    module StreamWindow
      # Upper clamp for ?tail=/?limit= — the display streams are MAXLEN 10000;
      # no legitimate window is bigger than a fifth of that.
      MAX = 500

      module_function

      # An entry's flat fields ([name, value, ...]) when the entry opens a message.
      def message_start?(fields)
        idx = fields.index("type")
        !idx.nil? && fields[idx + 1] == "message_start"
      end

      # The index at which the window holding the last `limit` messages starts
      # within chronological `entries` ([[entry_id, fields], ...]). nil/invalid
      # limit → 0 (everything); a stream holding fewer messages than the limit
      # also yields 0. Callers derive "more history" as a positive start.
      def window_start(entries, limit)
        return 0 unless limit&.positive?

        start = 0
        seen = 0
        (entries.length - 1).downto(0) do |i|
          seen += 1 if message_start?(entries[i][1])
          if seen >= limit
            start = i
            break
          end
        end
        start
      end

      # A raw ?tail=/?limit= param as a message count: nil/invalid/negative →
      # nil (no limit), otherwise clamped to 1..MAX.
      def parse_limit(raw)
        n = Integer(raw.to_s, 10)
        n.positive? ? [n, MAX].min : nil
      rescue ArgumentError, TypeError
        nil
      end

      # "<conversation_id>:<ms>-<seq>" or bare "<ms>-<seq>": the entry-id part
      # after the last ":" is the EXCLUSIVE XRANGE bound. Absent/unparseable →
      # `default` ("-" for replay-from-top, "+" for history-before).
      def bound(id, default)
        entry_id = id.to_s.split(":").last
        return default unless entry_id&.match?(/\A\d+-\d+\z/)

        "(#{entry_id}"
      end
    end
  end
end
