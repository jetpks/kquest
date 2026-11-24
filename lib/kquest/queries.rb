# frozen_string_literal: true

module Kquest
  # The storage query layer (I14 Part 5 — BRIEF §4 D2): named query objects
  # behind the seam, each transcribed from the FROZEN design SQL (I01
  # canonical-queries Q1–Q3, I02 §9/B1, I03 families a–d) — the semantics,
  # tiebreaks, and the RRF formula ARE the law. Every object is
  # Sequel-injectable (`conn:` kwarg, `Kquest::App["db.gateway"].connection`
  # default) and per-user scoping is a PARAMETER of every object (the :USER
  # law of the frozen families). plpgsql-free: recursive CTEs and plain
  # SQL only. No provider/model NAME literal appears anywhere in this
  # subsystem — registry uuids and registry-derived table names are the
  # sanctioned forms (G-REG).
  module Queries
    # The tool-config read every query object shares: the DB's `tool_config`
    # row over the Tools::DEFAULT_CONFIG fallback (rows win — the I13
    # pattern).
    module_function

    def config_value(conn, key)
      row = conn[:tool_config].where(key: key).first
      value = row ? (row.fetch(:num_value) || row.fetch(:text_value)) : Tools::DEFAULT_CONFIG.fetch(key)
      value.is_a?(Numeric) && !value.is_a?(Integer) && value.denominator == 1 ? value.to_i : value
    end

    # The staging corpus index (I14's Grounds ruling — the C-id law): the
    # quest's sources (ALL roles — agenda rows stage too) ordered by
    # (added_at, source_id); the C-id is the 1-based position. The SAME order
    # law the binding pass's citation index reserves (the citable subset,
    # same ordering) — source_list order, C-id resolution, and binding
    # ordinals are one law.
    def source_index(conn, user_id:, quest_id:)
      conn[:quest_sources]
        .join(:sources,
              Sequel[:sources][:id] => Sequel[:quest_sources][:source_id],
              Sequel[:sources][:user_id] => Sequel[:quest_sources][:user_id])
        .where(Sequel[:quest_sources][:quest_id] => quest_id,
               Sequel[:quest_sources][:user_id] => user_id)
        .order(Sequel[:quest_sources][:added_at], Sequel[:quest_sources][:source_id])
        .select_all(:sources)
        .to_a
    end

    # Resolve a source by C-id ("C13") or urn ("kb:src:…") within the
    # quest's staging corpus. Returns the sources row or nil.
    def resolve_source(conn, user_id:, quest_id:, ref:)
      index = source_index(conn, user_id: user_id, quest_id: quest_id)
      if ref.match(/\AC\d+\z/)
        index[ref.delete_prefix("C").to_i - 1]
      else
        index.find { |r| r[:urn] == ref }
      end
    end
  end
end
