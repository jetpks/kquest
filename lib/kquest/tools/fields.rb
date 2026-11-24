# frozen_string_literal: true

require "json"

module Kquest
  module Tools
    # The string-coercion layer with WRITE-BACK (I05 §4, T-COERCE / DR-02):
    # parse ONCE at each complex-type parameter boundary — only Strings whose
    # stripped form starts `{`/`[` AND parse (`JSON::ParserError` leaves the
    # value untouched, refusal voice unchanged); every downstream invariant
    # validates the PARSED value; the PARSED value is what every storage site
    # STORES (coerce-for-validation-only is FORBIDDEN — the cold-verifier
    # bomb). Coerced successes carry the frozen coercion note.
    module Fields
      # The tools' reserved top-level keys (never field values) per tool. For
      # node_add only the fusion trigger + label are structural: text/terminal
      # (claim form) and src/span/reading (evidence form) ARE the flat field
      # values (§3.3 — every key outside the reserved set is a field value).
      RESERVED = {
        "node_add"       => %w[label supports_new].freeze,
        "node_set"       => %w[node fields].freeze,
        "node_get"       => %w[node].freeze,
        "edge_add"       => %w[from type to].freeze,
        "frontier_add"   => %w[claim need uncertainty relevance].freeze,
        "frontier_close" => %w[claim closure_type].freeze,
        "search"         => %w[text label after].freeze,
        "list"           => %w[label after].freeze,
        "paths"          => %w[node].freeze,
        "neighbors"      => %w[node types direction].freeze,
        "source_read"    => %w[src offset limit].freeze,
        "source_grep"    => %w[src pattern ignore_case context].freeze,
        "source_list"    => %w[after].freeze,
        "web_search"     => %w[query max_results].freeze,
        "web_fetch"      => %w[url save].freeze,
        "retrieve"       => %w[query kinds limit quest model].freeze,
        "report_draft"   => %w[version section body].freeze,
        "report_bind"    => %w[version].freeze,
        "quest_status"   => [].freeze,
        "status"         => [].freeze,
        "mass"           => [].freeze,
        "subagent_spawn" => %w[profile band brief].freeze,
        "subagent_status" => %w[run].freeze
      }.freeze

      # Legal field names per label (§3.5 — composed into unknown-field refusals).
      LEGAL_FIELDS = {
        "claim"    => %w[text terminal].freeze,
        "evidence" => %w[src span reading].freeze,
        "need"     => %w[need uncertainty relevance].freeze
      }.freeze

      # The frozen stray-hints map (§3.4): on unknown-field refusals, where
      # the stray key belongs. The hint texts live here as DATA (the map's
      # rows are the design's own frozen table; tests pin them via the
      # composed refusal against the fixture line).
      STRAY_HINTS = {
        "basis"        => "basis/type belong INSIDE terminal: {\"type\":…,\"basis\":…}",
        "type"         => "basis/type belong INSIDE terminal: {\"type\":…,\"basis\":…}",
        "derives_from" => "derives_from is a CLAIM field / edge_add from,to — evidence carries " \
                          "src/span/reading",
        "text"         => "text is a CLAIM field; evidence carries src/span/reading instead",
        "label"        => "label is a TOP-LEVEL key of the call, never a field value",
        "src"          => "src is an EVIDENCE field; claims carry text/terminal"
      }.freeze

      module_function

      # The boundary rule: only Strings whose stripped form starts `{`/`[` AND
      # parse; anything else comes back untouched (the refusal voice is
      # unchanged for garbage — T4/T6).
      def coerce(value)
        return value unless value.is_a?(String)

        stripped = value.strip
        return value unless stripped.start_with?("{", "[")

        begin
          parsed = JSON.parse(stripped)
          parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : value
        rescue JSON::ParserError
          value
        end
      end

      def coerced?(value) = !value.equal?(coerce(value))

      # The flat/`fields` partition (T-NAME/DR-03): field values arrive FLAT
      # (every key outside the tool's reserved set) or nested under `fields:` —
      # ONE container name (`set:` does not exist). A key supplied both places
      # must carry the same value (the collision refusal data).
      def partition(tool, args)
        reserved = RESERVED.fetch(tool)
        fields = args.fetch(:fields, nil)
        fields = coerce(fields)
        unless fields.is_a?(Hash) || fields.nil?
          raise ArgumentError, "fields must be an object of field values, got #{fields.class}"
        end

        flat = args.reject { |k, _| reserved.include?(k.to_s) || k == :fields }
        nested = (fields || {}).transform_keys(&:to_sym)
        collision = flat.keys & nested.keys
        colliding = collision.select { |k| flat[k] != nested[k] }
        [flat, nested, colliding]
      end

      # Compose an unknown-field refusal's segments (§3.4/§3.5): the named
      # stray field + the label's legal fields + the stray's hint (when the
      # map knows it).
      def unknown_field_segments(tool, label, stray)
        named = "UNKNOWN-FIELD: #{stray} is not"
        of = "is not a field of #{label}"
        [named, of, stray]
      end
    end
  end
end
