# frozen_string_literal: true

require "json"

module Quest
  module Actions
    # GET /quests/:quest_id/briefing — the INTERACTIVE BRIEFING page (I17
    # Part 3 / I06 §8 + I08 §5.3): the quest row + state; the agenda list
    # (the quest's role-`agenda` sources via quest_sources ⋈ sources —
    # capped, surface `briefing`); the open briefing session state (Part
    # 0.1's current_session); the binding decompose round-1 phase id; the
    # current topic_questions (from that phase's `result` jsonb — the I03
    # DR-14 carrier) + the topic; and the `agenda_staged` gate state (the
    # transition law's own predicate shape: ≥1 agenda source — rendered
    # HONESTLY: sign-off without staged agenda leaves the worker
    # `awaiting_briefing`, presented, never blocked). OWNER-gated (Part 0.1).
    class BriefingIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        render_inertia(req, res, "Quests/Briefing", props: props(quest, user.id))
      end

      private

      def conn = gateway.connection

      def props(quest, user_id)
        qid = quest.fetch(:id)
        session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: qid)
        agenda = capped_agenda(qid, user_id)
        binding_phase = session && conn[:phases].where(id: session.fetch(:phase_id)).first
        questions = binding_phase && topic_questions(binding_phase)
        {
          quest: quest_props(quest),
          agenda: agenda,
          agenda_staged: agenda[:rows].any?,
          session: session && {id: session.fetch(:id), model: session.fetch(:model),
                               phase_id: session.fetch(:phase_id),
                               started_at: session.fetch(:started_at).iso8601},
          binding_phase_id: binding_phase && binding_phase.fetch(:id),
          binding_phase: binding_phase && "#{binding_phase.fetch(:kind)}" \
                                          "(#{binding_phase.fetch(:round_no)}/" \
                                          "#{binding_phase.fetch(:attempt_no)})",
          topic_questions: questions || [],
          topic: quest.fetch(:topic),
          console_url: "/quests/#{qid}/console",
          view_url: "/quests/#{qid}"
        }
      end

      def quest_props(quest)
        {id: quest.fetch(:id), topic: quest.fetch(:topic), state: quest.fetch(:state)}
      end

      # The agenda staging list: role-`agenda` sources joined on the quest —
      # capped (L15, surface `briefing`), most recently added first.
      def capped_agenda(quest_id, user_id)
        dataset = conn[:quest_sources]
                  .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
                  .where(Sequel[:quest_sources][:quest_id] => quest_id,
                         Sequel[:sources][:role] => "agenda")
                  .select(Sequel[:sources][:id], Sequel[:sources][:urn],
                          Sequel[:sources][:title], Sequel[:quest_sources][:added_at])
        Kquest::Ui::CappedListing.call(
          conn, dataset,
          surface: "briefing", user_id: user_id, quest_id: quest_id,
          order: [Sequel.desc(Sequel[:quest_sources][:added_at]), Sequel.desc(Sequel[:sources][:id])]
        )
      end

      # The I03 DR-14 carrier: the topic questions ride the binding phase's
      # `result` jsonb. The parsed jsonb object (Sequel's JSONBHash, a
      # Delegator) is duck-typed — its delegated is_a?(Hash) is unreliable in
      # this runtime; respond_to?(:key?) is the honest guard.
      def topic_questions(phase)
        result = phase.fetch(:result)
        result = JSON.parse(result) if result.is_a?(String)
        return [] unless result.respond_to?(:key?)

        questions = result["topic_questions"] || []
        questions.is_a?(Array) ? questions : []
      rescue JSON::ParserError
        []
      end
    end
  end
end
