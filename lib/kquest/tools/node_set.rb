# frozen_string_literal: true

module Kquest
  module Tools
    # Field updates on one node (I05 §2): values flat at the top level or
    # nested under `fields:` (one container name — DR-03); a nested null
    # deletes an optional field; a claim TERMINATES or DERIVES, never both
    # (the dual-arm refusal); urns are stamped, never supplied.
    class NodeSet < Base
      tool_name "node_set"

      parameters do
        {"type" => "object",
         "properties" => {
           "node" => {"type" => "string"},
           "fields" => {"type" => "object"},
           "text" => {"type" => "string"},
           "terminal" => {}
         },
         "required" => ["node"]}
      end

      def mutates? = true

      def execute(**args)
        # The boundary rule parses ONCE at the COMPLEX-TYPE parameters only —
        # a String field value (text) is stored verbatim (T6).
        args[:fields] = Fields.coerce(args[:fields]) if args.key?(:fields)
        node = find_claim(args[:node].to_s)
        refuse("node_set", "unknown-node", id: args[:node].to_s) unless node

        flat, nested, colliding = Fields.partition("node_set", args)
        if args.key?(:urn)
          refuse("node_set", "stamped-field")
        end

        unless colliding.empty?
          key = colliding.first
          refuse("node_set", "flat-nested-collision",
                 collision: "#{key} given twice (flat \"#{flat[key]}\" and fields: \"#{nested[key]}\")")
        end

        fields = flat.merge(nested)
        legal = Fields::LEGAL_FIELDS.fetch("claim")
        stray = fields.keys - legal.map(&:to_sym)
        if stray.any?
          refuse("node_set", "unknown-field",
                 named: "UNKNOWN-FIELD: #{stray.first} is not",
                 of: "is not a field of claim",
                 legal: "legal fields: #{legal.join(', ')}")
        end

        updates = {}
        notes = []
        if fields.key?(:text) && !fields[:text].nil?
          updates[:text] = fields[:text]
        end
        if fields.key?(:terminal)
          terminal = Fields.coerce(fields[:terminal])
          if Fields.coerced?(fields[:terminal])
            notes << coercion_note("terminal:string→object")
          end
          if terminal.nil?
            updates[:terminal_type] = nil
            updates[:terminal_basis] = nil
          else
            validate_terminal!(terminal)
            updates[:terminal_type] = terminal["type"]
            updates[:terminal_basis] = terminal["basis"]
          end
        end

        # The dual-arm law: a claim TERMINATES or DERIVES, never both.
        if updates[:terminal_type] && deriving?(node)
          refuse("node_set", "dual-arm", alias: claim_alias(node))
        end

        conn[:claims].where(id: node.fetch(:id)).update(updates) unless updates.empty?
        "#{claim_alias(node)} updated#{notes.map { |n| " #{n}" }.join}"
      end

      private

      def deriving?(node)
        conn[:claim_derivations].where(claim_id: node.fetch(:id)).count.positive?
      end

      def validate_terminal!(terminal)
        unless terminal.is_a?(Hash) &&
               %w[definitional-mathematical primary-empirical residual-uncertainty].include?(terminal["type"]) &&
               terminal["basis"].is_a?(String) && !terminal["basis"].strip.empty?
          # The frozen terminal-shape teaching text (node_add's fixture is the
          # contract for this exact shape — node_set freezes no second copy).
          raise Kquest::Engine::Error.new(Texts.refusal("node_add", "terminal-shape"),
                                          error_class: "TERMINAL-SHAPE")
        end
      end
    end
  end
end
