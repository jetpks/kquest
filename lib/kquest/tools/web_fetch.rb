# frozen_string_literal: true

module Kquest
  module Tools
    # Fetch + save (I05 §7.2): the wire fetches; registration rides the
    # landed Kquest::Pipeline::FetchBody (snapshot blob + content-addressed
    # sources row + quest_sources membership in ONE transaction —
    # auto-indexing; the source is anchorable in the SAME session); the
    # answer carries the frozen shape + the budget echo. Never re-fetch a
    # saved URL (fetch-once per user, D3).
    class WebFetch < Base
      tool_name "web_fetch"

      parameters do
        {"type" => "object",
         "properties" => {"url" => {"type" => "string"},
                          "save" => {"type" => "boolean"}},
         "required" => ["url"]}
      end

      def mutates? = true

      def execute(**args)
        check_budget!

        url = args[:url].to_s
        # duplicate-fetch: the URL (canonical form) is already saved —
        # fetch-once per user (D3); the read-the-saved-snapshot recipe.
        canonical = Kquest::Pipeline::CanonicalUrl.call(url)
        urn = urn_for(canonical)
        if urn
          source = conn[:sources].where(user_id: user_id, canonical_url: canonical).first
          c_id = "C" + (Kquest::Queries.source_index(conn, user_id: user_id, quest_id: quest_id)
                         .index { |r| r[:id] == source[:id] }.to_i + 1).to_s
          refuse("web_fetch", "duplicate-fetch",
                 src: c_id,
                 title_seg: "\"#{source.fetch(:title)}\" — never re-fetch")
        end

        row = WebWire.provider_row(conn)
        page = WebWire.fetch(row, url: url)

        # The ONE ingestion door (I08 §7): snapshot blob + sources row +
        # quest_sources membership in one transaction; role citable (fetched
        # pages are anchorable — the agent never writes corpus state).
        result = Kquest::Pipeline::FetchBody.call(
          user_id: user_id, url: url, title: page["title"], role: "citable",
          snapshot_text: page["text"], raw_body: page["text"],
          quest_id: quest_id, phase_id: phase_id
        )
        index = Kquest::Queries.source_index(conn, user_id: user_id, quest_id: quest_id)
        c_id = "C" + (index.index { |r| r[:id] == result[:source_id] }.to_i + 1).to_s

        "web_fetch: saved #{c_id} [#{result[:urn]}] \"#{page['title']}\" " \
          "#{page['text'].length} chars — anchorable now (node_add label=evidence src:\"#{c_id}\") " \
          "#{budget_echo}"
      end

      private

      # The saved-urn lookup (same user — D3's per-user fetch-once): derive
      # the urn the way FetchBody does (sha256 of canonical || snapshot) is
      # impossible pre-fetch, so detect a saved URL by its canonical_url.
      def urn_for(canonical)
        source = conn[:sources].where(user_id: user_id, canonical_url: canonical).first
        source && source.fetch(:urn)
      end

      def check_budget!
        quest = conn[:quests].where(id: quest_id).first
        used = web_calls_used
        cap = quest.fetch(:web_call_budget)
        mode = cfg_mode("engine.web_call_budget") || "advisory"
        return unless mode == "hard" && used >= cap

        refuse("web_fetch", "budget-exceeded", line: "web_calls=#{used}/#{cap}, mode=#{mode}")
      end

      def budget_echo
        quest = conn[:quests].where(id: quest_id).first
        Texts.budget_echo_note(used: web_calls_used + 1, cap: quest.fetch(:web_call_budget))
      end

      def web_calls_used
        conn[:tool_calls].where(quest_id: quest_id, ok: true)
                         .where(Sequel[:tool] => %w[web_search web_fetch]).count
      end
    end
  end
end
