# frozen_string_literal: true

require "json"

module Space
  module Server
    module Spaces
      # The space stream's event-envelope contract, shared by the SSE mux
      # action and the space history endpoint: envelope merge (conversation_id
      # / agent_role / agent_name / tag), the frozen display tag map, and
      # numeric entry-id ordering (a string compare is wrong at seq ≥ 10).
      # Entry-id bound parsing lives in StreamWindow (shared beyond spaces).
      module StreamEvents
        # Display tag map (frozen): the agent's role abbreviates when known;
        # otherwise a truncated agent name; otherwise the bare conversation id.
        ROLE_ABBREV = {
          "architect-coordinator" => "coord",
          "architect-spec" => "spec",
          "architect-judge" => "judge",
          "architect-builder" => "bld",
          "architect-narrator" => "narr"
        }.freeze

        module_function

        # The envelope-merged event object: the entry's data JSON (degraded to
        # {"type": ...} when it isn't a JSON object) merged at top level with
        # conversation identity and display tag.
        def merge_event(conversation_id, entry_id, fields, entry_meta)
          agent_role = entry_meta&.dig(:agent_role)
          agent_name = entry_meta&.dig(:agent_name)
          event = parsed_event(fields)
          event = { "type" => field(fields, "type") } unless event.is_a?(Hash)
          event.merge(
            "conversation_id" => conversation_id,
            "agent_role"      => agent_role,
            "agent_name"      => agent_name,
            "tag"             => tag(conversation_id, agent_role, agent_name)
          )
        end

        # The envelope-merged SSE frame (id line + data line).
        def sse_event(conversation_id, entry_id, fields, entry_meta)
          "id: #{conversation_id}:#{entry_id}\ndata: #{JSON.generate(merge_event(conversation_id, entry_id, fields, entry_meta))}\n\n"
        end

        # The entry's data field parsed as JSON, or {} when it isn't parseable.
        # Anything that isn't an object degrades at the merge (see #merge_event) —
        # events are never dropped.
        def parsed_event(fields)
          JSON.parse(field(fields, "data").to_s)
        rescue JSON::ParserError
          {}
        end

        # Flat Redis fields ([name, value, …]) — the first occurrence of name.
        def field(fields, name)
          idx = fields.index(name)
          idx ? fields[idx + 1] : nil
        end

        def tag(conversation_id, agent_role, agent_name)
          ROLE_ABBREV[agent_role] || agent_name&.to_s&.slice(0, 10) || "conv-#{conversation_id}"
        end

        # The delivered cursor comparison: the entry is at or before the cursor.
        def delivered_before?(cursor, entry_id)
          return false unless cursor

          (entry_key(entry_id) <=> cursor) <= 0
        end

        # Entry id "ms-seq" as a comparable numeric tuple.
        def entry_key(entry_id)
          parts = entry_id.to_s.split("-")
          [Integer(parts[0] || 0, 10), Integer(parts[1] || 0, 10)]
        rescue ArgumentError, TypeError
          [0, 0]
        end

        # An envelope id "<conversation_id>:<ms>-<seq>" as the per-conversation
        # XRANGE end bounds for history paging: the bound's own conversation gets
        # the exact exclusive entry id; every other conversation gets a
        # same-millisecond-exclusive bound — their seq counters aren't
        # comparable, and same-ms cross-conversation order is the stream's
        # documented ambiguity edge. Absent/unparseable → nil (no bound;
        # the caller's default).
        def history_bounds(id)
          parts = id.to_s.split(":")
          return nil unless parts.length == 2 && parts[1].match?(/\A\d+-\d+\z/)

          {
            conv_id: Integer(parts[0], 10),
            exact:   "(#{parts[1]}",
            other:   "(#{parts[1].split("-").first}-0"
          }
        end
      end
    end
  end
end
