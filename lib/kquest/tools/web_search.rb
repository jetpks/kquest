# frozen_string_literal: true

module Kquest
  module Tools
    # Query the web (I05 §7.1); EVERY result carries the frozen budget echo
    # `web_calls=<used>/<cap>` (advisory lines teach); when the web-call
    # budget line is HARD and exhausted the call is REFUSED before the wire
    # (the frozen text names the corpus tools + the never-reportless route).
    # Budget counting is DERIVED: the quest's tool_calls rows with tool IN
    # ('web_search','web_fetch','agenda_stage') AND ok — never stored (the
    # staging tool joined the predicate in I18: a wire fetch is a web call,
    # SR-02/D10).
    class WebSearch < Base
      tool_name "web_search"

      parameters do
        {"type" => "object",
         "properties" => {"query" => {"type" => "string"},
                          "max_results" => {"type" => "integer", "minimum" => 1, "maximum" => 20}},
         "required" => ["query"]}
      end

      def execute(**args)
        check_budget!

        row = WebWire.provider_row(conn)
        results = WebWire.search(row, query: args[:query], max_results: args[:max_results] || 5)
        lines = results.each_with_index.map do |r, i|
          "[#{i + 1}] #{r['url']} \"#{r['title']}\" — #{(r['text'] || '')[0, 200]}"
        end
        (lines + [budget_echo]).join("\n")
      end

      private

      # The web-call budget line: value = quests.web_call_budget (L9 — the
      # parity law); mode = the quest's process_config modes under the
      # registry key quest.web_call_budget (the quest_budget_mode source —
      # advisory by default, DR-09; a hard+exhausted line refuses BEFORE the
      # wire).
      def check_budget!
        quest = conn[:quests].where(id: quest_id).first
        used = web_calls_used
        cap = quest.fetch(:web_call_budget)
        mode = quest_budget_mode(quest)
        return unless mode == "hard" && used >= cap

        refuse("web_search", "budget-exceeded",
               line: "web_calls=#{used}/#{cap}, mode=#{mode}")
      end

      def budget_echo
        quest = conn[:quests].where(id: quest_id).first
        Texts.budget_echo_note(used: web_calls_used, cap: quest.fetch(:web_call_budget))
      end

      def web_calls_used
        conn[:tool_calls].where(quest_id: quest_id, ok: true)
                         .where(Sequel[:tool] => %w[web_search web_fetch agenda_stage]).count
      end
    end
  end
end
