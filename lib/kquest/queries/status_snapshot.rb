# frozen_string_literal: true

module Kquest
  module Queries
    # The parity reads (I14 Part 5.6 / I05 §5 — T-GATE): the `status` field
    # set (aggregates over the SAME law views any phase gate sweeps:
    # v_claim_closure, v_decompose_remaining, v_frontier_mass, v_frontier_open)
    # and the `quest_status` fields (quest state, phase display, writer, the
    # three DERIVED budget lines). EXACTLY the §5 parity fields, no decorative
    # additions — check-coverage.sh machine-checks the parity block 1:1 both
    # directions.
    class StatusSnapshot
      def initialize(conn:)
        @conn = conn
      end

      # The `status` dashboard: the eight frozen fields.
      def status_fields(user_id:, quest_id:)
        claims = @conn[:claims].where(user_id: user_id, quest_id: quest_id).count
        evidence = @conn[:evidence].where(user_id: user_id, quest_id: quest_id).count
        closure = @conn[:v_claim_closure].where(quest_id: quest_id)
        bare = closure.where(bare: true).count
        unreferenced = closure.where(Sequel.lit("evidence_count = 0")).count
        dual_arm = closure.where(Sequel.lit("has_terminal AND derives_from_count > 0")).count
        decompose_remaining =
          @conn[:v_decompose_remaining].where(quest_id: quest_id).get(:unmined_citable) || 0
        mass_row = @conn[:v_frontier_mass].where(quest_id: quest_id).first
        {
          claims: claims, evidence: evidence,
          decompose_remaining: decompose_remaining,
          frontier_open: mass_row ? mass_row.fetch(:open_entries) : 0,
          frontier_mass: mass_row ? mass_row.fetch(:mass) : 0,
          bare_claims: bare, unreferenced: unreferenced, dual_arm_claims: dual_arm
        }
      end

      # The `quest_status` lines: the three budget lines are DERIVED (L10 —
      # the ledger is the counter, never a stored value):
      #   web_calls — the quest's tool_calls rows with tool IN
      #               ('web_search','web_fetch') AND ok (each web call IS a
      #               tool call — exact counting; a refused call made no wire
      #               call and does not count);
      #   tokens    — the quest's usage_events rollup vs quests.token_budget;
      #   spend_usd — the quest's usage_events cost rollup vs
      #               quests.spend_budget_usd.
      def quest_fields(user_id:, quest_id:, session_id:)
        quest = @conn[:quests].where(id: quest_id, user_id: user_id).first
        raise Kquest::Engine::Error, "quest #{quest_id} not found" unless quest

        phase = @conn[:phases]
                .join(:sessions, Sequel[:sessions][:phase_id] => Sequel[:phases][:id])
                .where(Sequel[:sessions][:id] => session_id).first
        web_used = @conn[:tool_calls]
                   .where(quest_id: quest_id, ok: true)
                   .where(Sequel[:tool] => %w[web_search web_fetch]).count
        tokens_used = @conn[:usage_events].where(quest_id: quest_id)
                                          .sum(Sequel.lit("input_tokens + output_tokens + " \
                                                          "cache_read_tokens + cache_write_tokens")) || 0
        spend_used = @conn[:usage_events].where(quest_id: quest_id)
                                         .sum(:cost_usd) || BigDecimal("0")
        {
          quest: quest.fetch(:state),
          phase: phase ? "#{phase.fetch(:kind)}(#{phase.fetch(:round_no)}/#{phase.fetch(:attempt_no)})" : nil,
          writer: "session/#{session_id.to_s[0, 4]}",
          web_used: web_used, web_cap: quest.fetch(:web_call_budget),
          tokens_used: tokens_used, tokens_cap: quest.fetch(:token_budget),
          spend_used: BigDecimal(spend_used.to_s), spend_cap: quest.fetch(:spend_budget_usd)
        }
      end

      # The SESSIONLESS parity variant (I17 Part 0.3, the F6 extraction): the
      # three budget lines + quest state derived with NO session-bearing
      # query — the SQL shape quest_show.rb#derived_fields carried, extracted
      # VERBATIM (no second SQL copy; the I14 composed-constants law). The
      # optional session kwarg preserves the landed viewer degradation
      # (phase/writer from the latest session when one exists — the quest
      # view's behavior byte-preserved); the console composes without it.
      # Both callers render through the SHARED QuestStatus.line —
      # byte-faithfulness by construction.
      def self.quest_fields_sessionless(conn, quest_id:, session: nil)
        quest = conn[:quests].where(id: quest_id).first
        raise Kquest::Engine::Error, "quest #{quest_id} not found" unless quest

        phase = session && conn[:phases].where(id: session[:phase_id]).first
        spend_used = conn[:usage_events].where(quest_id: quest_id).sum(:cost_usd) || BigDecimal("0")
        {
          quest: quest.fetch(:state),
          phase: phase && "#{phase.fetch(:kind)}(#{phase.fetch(:round_no)}/#{phase.fetch(:attempt_no)})",
          writer: session && "session/#{session[:id].to_s[0, 4]}",
          web_used: conn[:tool_calls].where(quest_id: quest_id, ok: true)
                                     .where(Sequel[:tool_calls][:tool] => %w[web_search web_fetch]).count,
          web_cap: quest.fetch(:web_call_budget),
          tokens_used: conn[:usage_events].where(quest_id: quest_id)
                                          .sum(Sequel.lit("input_tokens + output_tokens + " \
                                                          "cache_read_tokens + cache_write_tokens")) || 0,
          tokens_cap: quest.fetch(:token_budget),
          spend_used: BigDecimal(spend_used.to_s),
          spend_cap: quest.fetch(:spend_budget_usd)
        }
      end
    end
  end
end
