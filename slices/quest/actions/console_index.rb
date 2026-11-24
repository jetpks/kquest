# frozen_string_literal: true

module Quest
  module Actions
    # GET /quests/:quest_id/console — THE STEERING CONSOLE (I17 Part 1 / I08
    # §4 row 6): the parity block (composed through the sessionless variant +
    # the SHARED QuestStatus.line — byte-faithful by construction), the menus
    # (Part 0.2's pure derivation — presented, never enforced), the
    # routing-map editor data (ladder_passes rows cited per model, reviewable
    # — never a blocker, I07 DR-06), the stop_rules config rows echoed (the
    # menus' evidence), the capped steering history, the mute rows for THIS
    # quest (key/provenance — who/why), the open operator session state, and
    # the read-only live view on the I15 FROZEN stream URL (the shared
    # EventFeed). While `active` the page renders the live view + the landed
    # pause button ONLY — the client renders every steering control DISABLED
    # from state (the disablement is structural, I08 §5.2). The ?alert=
    # param pre-loads the adjudication pointer. OWNER-gated (Part 0.1 — 404
    # non-owner BEFORE any prop assembly; the I16 read surfaces keep
    # visible_quest?). Listings cap through CappedListing (surface console —
    # L15: "showing N of M", never silent truncation).
    class ConsoleIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        render_inertia(req, res, "Quests/Console", props: props(quest, user.id, req.params[:alert]))
      end

      private

      def conn = gateway.connection

      def props(quest, user_id, alert_param)
        qid = quest.fetch(:id)
        stop_rules = conn[:stop_rules].order(:rule_id).to_a
        {
          quest: quest_props(quest),
          parity_line: Kquest::Tools::QuestStatus.line(
            Kquest::Queries::StatusSnapshot.quest_fields_sessionless(conn, quest_id: qid)
          ),
          menus: Kquest::Ui::ConsoleMenus.derive(
            quest: quest,
            latest_note: latest_orchestrator_note(qid),
            latest_phase: latest_phase(qid),
            alert_param: alert_param,
            stop_rules: stop_rules
          )[:menus],
          alert_param: alert_param,
          ladder_passes: capped_ladder(qid, user_id),
          stop_rules: stop_rules.map { |r| stop_rule_props(r) },
          lifecycle: capped_lifecycle(qid, user_id),
          mutes: capped_mutes(qid, user_id),
          session: session_props(Kquest::Ui::OperatorWrite.current_session(conn, quest_id: qid)),
          stream_url: "/quests/#{qid}/stream",
          view_url: "/quests/#{qid}",
          briefing_url: "/quests/#{qid}/briefing"
        }
      end

      def quest_props(quest)
        {
          id: quest.fetch(:id), topic: quest.fetch(:topic), state: quest.fetch(:state),
          web_call_budget: quest.fetch(:web_call_budget),
          token_budget: quest.fetch(:token_budget),
          spend_budget_usd: quest.fetch(:spend_budget_usd).to_s("F"),
          process_config: quest.fetch(:process_config),
          model_config: quest.fetch(:model_config)
        }
      end

      def stop_rule_props(row)
        {rule_id: row[:rule_id], scope: row[:scope], metric: row[:metric],
         default: row[:default].to_s("F"), operator: row[:operator], action: row[:action],
         config_key: row[:config_key]}
      end

      def session_props(session)
        return nil unless session

        {id: session.fetch(:id), model: session.fetch(:model),
         started_at: session.fetch(:started_at).iso8601, phase_id: session.fetch(:phase_id)}
      end

      # The menus' durable-state inputs: the latest ORCHESTRATOR-actor note
      # (the PROCESS_STOP tokens are the runner's loud_note output; the
      # operator's own door notes carry no trigger tokens) + the latest
      # phase row.
      def latest_orchestrator_note(quest_id)
        row = conn[:quest_lifecycle_events].where(quest_id: quest_id, actor: "orchestrator")
                                           .order(Sequel.desc(:occurred_at), Sequel.desc(:id))
                                           .first
        row && row.fetch(:note)
      end

      def latest_phase(quest_id)
        conn[:phases].where(quest_id: quest_id)
                     .order(Sequel.desc(:created_at), Sequel.desc(:id)).first
      end

      # The listings (L15): the surface's cap row + telemetry, "showing N of
      # M" carried to the page from the returned fields.
      def capped_ladder(quest_id, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:ladder_passes],
          surface: "console", user_id: user_id, quest_id: quest_id,
          order: [Sequel.desc(:passed_at), Sequel.desc(:id)]
        )
      end

      def capped_lifecycle(quest_id, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:quest_lifecycle_events].where(quest_id: quest_id),
          surface: "console", user_id: user_id, quest_id: quest_id,
          order: [Sequel.desc(:occurred_at), Sequel.desc(:id)]
        )
      end

      def capped_mutes(quest_id, user_id)
        Kquest::Ui::CappedListing.call(
          conn, conn[:tool_config].where(Sequel.like(:key, "alerts.mute.#{quest_id}.%")),
          surface: "console", user_id: user_id, quest_id: quest_id,
          order: [Sequel.asc(:key)]
        )
      end
    end
  end
end
