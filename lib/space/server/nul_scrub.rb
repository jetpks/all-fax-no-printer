# frozen_string_literal: true

module Space
  module Server
    # Postgres text/jsonb columns reject the NUL byte outright
    # (PG::UntranslatableCharacter) — recursively strip it from anything about
    # to be persisted. Shared by Conversations::Persistor, the place transcript content
    # reaches the database. (Was Importers::NulScrub; the importer tier died
    # with the I06 cut, the scrubbing didn't — recovered from the
    # pre-observation-deck tag.)
    module NulScrub
      module_function

      def scrub_nul(value)
        case value
        when String then value.delete("\0")
        when Array  then value.map { |v| scrub_nul(v) }
        when Hash   then value.transform_values { |v| scrub_nul(v) }
        else value
        end
      end
    end
  end
end