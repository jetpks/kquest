# frozen_string_literal: true

module Kquest
  module Tools
    # Stage an agenda document from the web (I18 the §8 amendment — the
    # agent's write, steered conversationally in the briefing chat): a
    # budget-checked WIRE FETCH through the same wire the web tools use
    # (`WebWire.fetch`), staged through the ONE ingestion door
    # (`Kquest::Pipeline::FetchBody`, role `agenda` — content-addressed;
    # re-staging registers membership only). The source is role-`agenda`:
    # readable direction, NEVER anchorable or citable (I06 §8's law,
    # R-003 — schema-native exclusion from the decompose gate). The web-call
    # budget is the tools' extended predicate (three names — a wire fetch is
    # a web call, SR-02/D10); hard+exhausted refuses BEFORE the wire; the
    # budget echo rides every answer.
    #
    # NO frozen I05 fixture (the Grounds law): the description below opens
    # with the canonical call (the T-CALL shape, in code) and the refusals
    # are teaching refusals raised as `Kquest::Engine::Error` carrying the
    # census-able rule-id token as `error_class` — audited ok=false through
    # the standard harness path.
    class AgendaStage < Base
      tool_name "agenda_stage"

      CANONICAL_CALL = 'agenda_stage url="https://…" title="…"'.freeze

      DESCRIPTION = <<~DESC.freeze
        ```#{CANONICAL_CALL}``` — fetch a web page and STAGE it as an agenda
        document for this quest's briefing. Agenda sources are readable
        direction: mine them for needs, questions, and structure — NEVER
        anchor evidence to them, NEVER cite them (they are excluded from the
        decompose gate by schema). The web-call budget counts this staging
        fetch (the echo below each answer). `title` is optional (the page's
        own title is used when absent).
      DESC

      parameters do
        {"type" => "object",
         "properties" => {"url" => {"type" => "string"},
                          "title" => {"type" => "string"}},
         "required" => ["url"]}
      end

      def description = DESCRIPTION

      def mutates? = true

      def execute(**args)
        url = args[:url].to_s
        if url.strip.empty?
          raise Kquest::Engine::Error.new(
            "REFUSAL: AGENDA-URL-REQUIRED: `agenda_stage` needs the page's url — " \
            "#{CANONICAL_CALL} (a staging fetch IS a web call; the budget echo shows the count)",
            error_class: "AGENDA-URL-REQUIRED"
          )
        end

        check_budget!

        page = WebWire.fetch(WebWire.provider_row(conn), url: url)
        title = args[:title].to_s.strip.empty? ? page["title"] : args[:title].to_s
        result = Kquest::Pipeline::FetchBody.call(
          user_id: user_id, url: url, title: title, role: "agenda",
          snapshot_text: page["text"], raw_body: page["text"],
          quest_id: quest_id, phase_id: phase_id
        )
        idem = result.fetch(:created) ? "" : " (already staged — membership registered)"
        "agenda_stage: staged #{result.fetch(:urn)} \"#{title}\" #{page['text'].length} chars" \
          "#{idem} — agenda sources are readable direction, never anchorable or citable " \
          "(mine them for needs; never anchor, never cite)\n" \
          "preview: #{page['text'][0, 200]}\n" \
          "#{budget_echo}"
      end

      private

      # The web-call budget line (the same law as the web tools): value =
      # quests.web_call_budget (L9 — the parity law); mode = the
      # engine_config line's mode (advisory by default, DR-09; hard+exhausted
      # refuses BEFORE the wire).
      def check_budget!
        quest = conn[:quests].where(id: quest_id).first
        used = web_calls_used
        cap = quest.fetch(:web_call_budget)
        mode = cfg_mode("engine.web_call_budget") || "advisory"
        return unless mode == "hard" && used >= cap

        raise Kquest::Engine::Error.new(
          "REFUSAL: BUDGET-EXCEEDED: the web-call budget line for this quest is exhausted " \
          "(web_calls=#{used}/#{cap}, mode=#{mode}) — work the staged agenda instead; " \
          "a budget stop routes loudly, never a silent stop",
          error_class: "BUDGET-EXCEEDED"
        )
      end

      def budget_echo
        quest = conn[:quests].where(id: quest_id).first
        Texts.budget_echo_note(used: web_calls_used + 1, cap: quest.fetch(:web_call_budget))
      end

      # The extended derived predicate (three names — Grounds §4.5/§5.7): a
      # staging fetch IS a web call (SR-02 honesty); ok-only, never stored.
      def web_calls_used
        conn[:tool_calls].where(quest_id: quest_id, ok: true)
                         .where(Sequel[:tool] => %w[web_search web_fetch agenda_stage]).count
      end
    end
  end
end
