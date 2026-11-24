# frozen_string_literal: true

require "fast/completions"

module Kquest
  # The I05 tool surface (I14): 23 callable tools + the `harness` census
  # name, built on the landed ToolHarness contract. Every tool is a
  # `Fast::Completions::Tool` subclass whose description opens with its
  # canonical call (T-CALL — read from the frozen fixture at runtime); every
  # refusal is `Kquest::Engine::Error` carrying the frozen fixture line with
  # its located slots substituted (DR-01/T-LOCATE) and the census-able
  # rule-id as `error_class`; tenancy comes from the session binding (no
  # tool takes a user parameter — I01 DR-01).
  module Tools
    # The frozen fallback config (the I13 Engine::DEFAULT_CONFIG pattern): DB
    # rows win over these when present, so a mutated seed value heals at the
    # next prepare and a tool constructed against an empty table still
    # carries the design law. The two dedup constants are the CALIBRATED
    # values from the live recalibration run — provenance source:
    # script/dedup_calibration/record.md (I05 DR-07 ruling A / I03 DR-15).
    DEFAULT_CONFIG = {
      "tools.cap_search_rows"          => 20,
      "tools.cap_search_snippet_chars" => 120,
      "tools.cap_list_rows"            => 50,
      "tools.cap_neighbors"            => 50,
      "tools.cap_paths_depth"          => 128,
      "tools.cap_source_list_rows"     => 50,
      "tools.cap_report_section_chars" => 20_000,
      "tools.claim_embedding_model"    => "92000000-0000-4000-8000-000000000001",
      "tools.dedup_near_top_k"         => 2,
      "tools.dedup_near_floor"         => 0.8387
    }.freeze

    # The ordered 24-name inventory (I05 §2's `tools` block verbatim — the
    # census order). `harness` is a census name, not a callable tool: its
    # three dispatch texts are the landed ToolHarness law (I13); the callable
    # registered surface is the 23.
    INVENTORY = %w[
      node_add node_set node_get edge_add frontier_add frontier_close
      status search list paths mass neighbors
      source_read source_grep source_list
      web_search web_fetch
      retrieve
      report_draft report_bind
      harness quest_status subagent_spawn subagent_status
    ].freeze

    # The callable tool classes by name (the 23; Zeitwerk: Kquest::Tools::<Name>).
    TOOL_CLASSES = {
      "node_add"        => "NodeAdd",
      "node_set"        => "NodeSet",
      "node_get"        => "NodeGet",
      "edge_add"        => "EdgeAdd",
      "frontier_add"    => "FrontierAdd",
      "frontier_close"  => "FrontierClose",
      "status"          => "Status",
      "search"          => "Search",
      "list"            => "List",
      "paths"           => "Paths",
      "mass"            => "Mass",
      "neighbors"       => "Neighbors",
      "source_read"     => "SourceRead",
      "source_grep"     => "SourceGrep",
      "source_list"     => "SourceList",
      "web_search"      => "WebSearch",
      "web_fetch"       => "WebFetch",
      "retrieve"        => "Retrieve",
      "report_draft"    => "ReportDraft",
      "report_bind"     => "ReportBind",
      "quest_status"    => "QuestStatus",
      "subagent_spawn"  => "SubagentSpawn",
      "subagent_status" => "SubagentStatus"
    }.freeze

    module_function

    # The tool config lines: {key => value} — the DB's `tool_config` rows
    # over the frozen defaults (the Engine.config pattern).
    def config(conn)
      defaults = DEFAULT_CONFIG.dup
      conn[:tool_config].each do |row|
        defaults[row.fetch(:key)] = row.fetch(:num_value) || row.fetch(:text_value)
      end
      defaults
    end

    # A config value as a plain number (numeric values arrive as BigDecimal).
    # Lines may arrive PLAIN (Tools.config's shape) or as {value:, mode:}
    # hashes (the Engine.config shape the harness carries) — both accepted.
    def config_value(lines, key)
      line = lines.fetch(key)
      value = line.is_a?(Hash) ? line.fetch(:value) : line
      value.is_a?(Numeric) && !value.is_a?(Integer) && value.denominator == 1 ? value.to_i : value
    end

    # The line's mode (advisory|hard) — read ONLY by budget-guard consumers
    # (DR-09); nil for plain-value lines (advisory by default).
    def config_mode(lines, key)
      line = lines[key]
      line.is_a?(Hash) ? line.fetch(:mode, nil) : nil
    end

    # Constructs ONE tool instance bound to the session's tenancy. The
    # session hash carries user_id/quest_id/phase_id (+ id, model, driver) —
    # the same shape ProviderDesk/Ledger consume.
    def build(name, conn:, session:, ledger:, config:, runner: nil)
      klass = TOOL_CLASSES.fetch(name) do
        raise KeyError, "no callable tool named #{name.inspect} " \
                        "(census names are not callable; the legal surface is the registered list)"
      end
      Kquest::Tools.const_get(klass).new(conn: conn, session: session, ledger: ledger,
                                         config: config, runner: runner)
    end

    # The callable list for a surface (the 23; census names filtered — a
    # literal call to the name `harness` lands in the unknown-tool path and
    # is taught the legal list). Instances pre-bound to the tenancy.
    def registry(names, conn:, session:, ledger:, config:, runner: nil)
      names.reject { |n| n == "harness" }.map do |name|
        build(name, conn: conn, session: session, ledger: ledger, config: config, runner: runner)
      end
    end

    # Resolve a subagent profile row into its callable tool list (I05 §8: the
    # profile IS the registration).
    def profile_tools(conn, name)
      row = conn[:subagent_profiles].where(name: name).first
      return nil unless row

      tools = row.fetch(:tools)
      tools.is_a?(String) ? JSON.parse(tools) : tools
    end

    # The base class: config/tenancy injection + the refusal helpers.
    class Base < Fast::Completions::Tool
      def initialize(conn:, session:, ledger:, config:, runner: nil)
        @conn = conn
        @session = session
        @ledger = ledger
        @config = config
        @runner = runner
      end

      attr_reader :conn, :session, :config

      # T-CALL: the registered description OPENS with the canonical call(s)
      # (read from the frozen fixture at runtime — never copied).
      def description = Texts.canonical_description(self.class.tool_name)

      def mutates? = false

      private

      def user_id = session.fetch(:user_id)
      def quest_id = session.fetch(:quest_id)
      def phase_id = session.fetch(:phase_id)

      def cfg(key)
        return Tools.config_value(config, key) if config.key?(key)

        # engine.* lines live in the Engine config (the harness's own lines);
        # a tool-config-less caller still gets the frozen defaults.
        Kquest::Engine.config_value(Kquest::Engine.config(conn), key)
      end

      def cfg_mode(key)
        return Tools.config_mode(config, key) if config.key?(key)

        Kquest::Engine.config(conn).fetch(key, {}).fetch(:mode, nil)
      end

      # The frozen refusal (T-LOCATE/DR-01): the fixture line with its slots
      # substituted, raised as the engine's only error type with the
      # census-able rule-id token as error_class.
      def refuse(tool, class_id, **slots)
        raise Kquest::Engine::Error.new(Texts.refusal(tool, class_id, **slots),
                                        error_class: Texts.error_class(tool, class_id))
      end

      # The §3.9 success notes (pinned constants in Texts — byte-tested
      # against DESIGN.md §3.9 by the loader's tests).
      def bare_note = Texts.bare_note
      def unreferenced_note = Texts.unreferenced_note
      def coercion_note(what) = Texts.coercion_note(what)
      def dedup_note(candidates)
        candidates = candidates.join(", ") if candidates.is_a?(Array)
        Texts.dedup_candidates_note(candidates)
      end
      def cap_note(n:, last_id:) = Texts.cap_note(n: n, last_id: last_id)

      # ── shared tenancy lookups ──────────────────────────────────────────

      # Resolve a node reference: a K-alias ("K24") or a claim urn
      # ("kb:claim:…") within THIS quest. Returns the claims row or nil.
      def find_claim(ref)
        if ref.match(/\AK\d+\z/)
          conn[:claims].where(user_id: user_id, quest_id: quest_id,
                              quest_seq: ref.delete_prefix("K").to_i).first
        else
          conn[:claims].where(user_id: user_id, quest_id: quest_id, urn: ref).first
        end
      end

      def claim_alias(row) = "K#{row.fetch(:quest_seq)}"

      # The E-id display ordinal (I14's Grounds ruling — display layer, not
      # schema): dense row_number over the quest's evidence by (created_at, id).
      def evidence_ordinal(row)
        conn[:evidence]
          .where(user_id: user_id, quest_id: quest_id)
          .where(Sequel.lit("(created_at, id) <= (?, ?)", row.fetch(:created_at), row.fetch(:id)))
          .count
      end

      def evidence_by_ordinal(ordinal)
        conn[:evidence]
          .where(user_id: user_id, quest_id: quest_id)
          .order(:created_at, :id)
          .offset(ordinal - 1).limit(1).first
      end

      # Mint the quest-salted claim urn (I01 DR-06, the pipeline fixture's
      # own derivation): kb:claim: + base58(sha256(quest_id || canonical)).
      def mint_claim_urn(canonical_text)
        require "digest"
        "kb:claim:" + Kquest::Pipeline::Base58
          .encode(Digest::SHA256.digest("#{quest_id}#{canonical_text}"))[0, 10]
      end

      # The frozen canonical normalizer (the GENERATED column's definition —
      # the same mirror PipelineFixtures carries).
      def canonicalize(text)
        text.gsub(/[ \t\n\r\f\v]+/, " ").strip
          .gsub(/\A[ \t\n\r\f\v]+|[ \t\n\r\f\v]+\z/, "")
          .unicode_normalize(:nfc)
      end
    end
  end
end
