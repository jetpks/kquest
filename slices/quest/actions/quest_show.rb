# frozen_string_literal: true

module Quest
  module Actions
    # GET /quests/:quest_id — the quest VIEW (I08 §4 row 2 / I16 Part 1): the
    # parity block, the capped lifecycle ledger / sessions / phases, the
    # unmined + frontier counters, the read-only config, the quest
    # fingerprint, and the live event feed on the I15 FROZEN stream URL.
    # Console/briefing links are I17's — never rendered, never stubbed.
    #
    # NOTE: slice action objects are FROZEN singletons — no per-request
    # ivars; the requesting user's id rides the method parameters.
    class QuestShow < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless visible_quest?(user.id, quest_id)
        quest = conn[:quests].where(id: quest_id).first

        render_inertia(req, res, "Quests/Show", props: props(quest, user.id))
      end

      private

      def conn = gateway.connection

      # THE one shared visibility gate (I08 §4) — non-visible quests 404
      # BEFORE any prop assembly; existence is never leaked.
      def visible_quest?(user_id, quest_id)
        Kquest::Ui::Visibility.visible_quest?(conn, user_id: user_id, quest_id: quest_id)
      end

      def props(quest, user_id)
        qid = quest.fetch(:id)
        session = conn[:sessions].where(quest_id: qid)
                                  .order(Sequel.desc(:started_at), Sequel.desc(:id)).first
        {
          quest: quest_props(quest),
          parity_line: Kquest::Tools::QuestStatus.line(parity_fields(quest, session, user_id)),
          lifecycle: capped_lifecycle(quest, user_id),
          sessions: capped_sessions(quest, user_id),
          phases: capped_phases(quest, user_id),
          counters: counters(quest),
          fingerprint: conn[:v_quest_graph_fingerprint].where(quest_id: qid)
                                                       .get(:graph_fingerprint),
          stream_url: "/quests/#{qid}/stream",
          frontier_url: "/quests/#{qid}/frontier",
          graph_url: "/quests/#{qid}/graph",
          report_url: "/quests/#{qid}/report"
        }
      end

      def quest_props(quest)
        {
          id: quest.fetch(:id), topic: quest.fetch(:topic), state: quest.fetch(:state),
          provenance_kind: quest.fetch(:provenance_kind), created_at: quest.fetch(:created_at),
          web_call_budget: quest.fetch(:web_call_budget),
          token_budget: quest.fetch(:token_budget),
          spend_budget_usd: quest.fetch(:spend_budget_usd).to_s("F"),
          process_config: quest.fetch(:process_config),
          model_config: quest.fetch(:model_config)
        }
      end

      # The parity block's fields (I05 §5): through StatusSnapshot.quest_fields
      # when the owner's latest session exists; else the SESSIONLESS variant
      # (I17 Part 0.3 — the same derivations, extracted verbatim into
      # Kquest::Queries::StatusSnapshot.quest_fields_sessionless; no second
      # SQL copy). #quest_fields requires a session_id (writer segment) and a
      # row owned by the requesting user, and the read surfaces must render
      # without either (pre-briefing quests; public-source viewers). Both
      # paths compose through the SHARED QuestStatus.line — never a copy.
      def parity_fields(quest, session, user_id)
        if session && quest.fetch(:user_id) == user_id
          Kquest::Queries::StatusSnapshot.new(conn: conn)
            .quest_fields(user_id: user_id, quest_id: quest.fetch(:id),
                          session_id: session.fetch(:id))
        else
          Kquest::Queries::StatusSnapshot.quest_fields_sessionless(
            conn, quest_id: quest.fetch(:id), session: session
          )
        end
      end

      # The listings (L15): principled deterministic order + the config cap +
      # telemetry, via the ONE shared helper.
      def capped_lifecycle(quest, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:quest_lifecycle_events].where(quest_id: quest.fetch(:id)),
          surface: "quest", user_id: user_id, quest_id: quest.fetch(:id),
          order: [Sequel.desc(:occurred_at), Sequel.desc(:id)]
        )
      end

      def capped_sessions(quest, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:sessions].where(quest_id: quest.fetch(:id)),
          surface: "quest", user_id: user_id, quest_id: quest.fetch(:id),
          order: [Sequel.desc(:started_at), Sequel.desc(:id)]
        )
      end

      def capped_phases(quest, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:phases].where(quest_id: quest.fetch(:id)),
          surface: "quest", user_id: user_id, quest_id: quest.fetch(:id),
          order: [Sequel.asc(:created_at), Sequel.asc(:id)]
        )
      end

      # The counters (I16 Part 1): v_unmined_sources/v_decompose_remaining +
      # the frontier mass fuse — read-only over the law views.
      def counters(quest)
        qid = quest.fetch(:id)
        mass_row = conn[:v_frontier_mass].where(quest_id: qid).first
        {
          unmined_citable: conn[:v_decompose_remaining].where(quest_id: qid)
                                                       .get(:unmined_citable) || 0,
          frontier_open: mass_row ? mass_row.fetch(:open_entries) : 0,
          frontier_mass: mass_row ? mass_row.fetch(:mass) : 0
        }
      end
    end
  end
end
