# frozen_string_literal: true

module Space
  module Server
    module Iterations
      # Flattens dry-validation's nested error tree (hashes keyed by field name
      # or array index) into one string per failing path, e.g.
      # "gates[0].id is missing" — the shape the ingest mouths return as
      # {errors: [...]} on a 422.
      module ContractErrors
        module_function

        def flatten(node, path = [])
          case node
          when Hash
            node.flat_map { |key, child| flatten(child, path + [key]) }
          when Array
            node.flat_map { |child| child.is_a?(String) ? [render(path, child)] : flatten(child, path) }
          else
            [render(path, node.to_s)]
          end
        end

        def render(path, message)
          "#{path.map { |part| part.is_a?(Integer) ? "[#{part}]" : ".#{part}" }.join.sub(/\A\./, "")} #{message}"
        end
      end
    end
  end
end
