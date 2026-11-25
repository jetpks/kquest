# frozen_string_literal: true

require "json"

module Quest
  module Actions
    # GET /quests/:quest_id/briefing — the CHAT page (I18 the §8 amendment;
    # was the I17 staging-forms briefing): the quest row + state; the agenda
    # list (the quest's role-`agenda` sources via quest_sources ⋈ sources —
    # capped, surface `briefing`, the UNCHANGED query); the open briefing
    # session state; the binding decompose round-1 phase id; the current
    # topic_questions (from that phase's `result` jsonb — the I03 DR-14
    # carrier) + the topic; the TRANSCRIPT (the ledger blob replayed through
    # the reader's sink seam — BriefingTranscript.for_session, tail-capped
    # with the honest omitted count) + the QUEUED (still-`enqueued` operator
    # turns of the open session — the worker's service order); and the
    # `agenda_staged` gate state (the transition law's own predicate shape:
    # ≥1 agenda source — rendered HONESTLY: sign-off without staged agenda
    # leaves the worker `awaiting_briefing`, presented, never blocked).
    # OWNER-gated (Part 0.1). The agenda/gate/questions render AS TRANSCRIPT
    # CONTEXT — never as forms.
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
          session: session && {id: session.fetch(:id), model: session.fetch(:model),
                               phase_id: session.fetch(:phase_id),
                               started_at: session.fetch(:started_at).iso8601},
          agenda: agenda,
          agenda_staged: agenda[:rows].any?,
          topic_questions: questions || [],
          topic: quest.fetch(:topic),
          transcript: transcript(session),
          queued: queued(session),
          unsent: unsent(qid),
          binding_phase_id: binding_phase && binding_phase.fetch(:id),
          binding_phase: binding_phase && "#{binding_phase.fetch(:kind)}" \
                                          "(#{binding_phase.fetch(:round_no)}/" \
                                          "#{binding_phase.fetch(:attempt_no)})",
          stream_url: "/quests/#{qid}/stream",
          console_url: "/quests/#{qid}/console",
          view_url: "/quests/#{qid}"
        }
      end

      def quest_props(quest)
        {id: quest.fetch(:id), topic: quest.fetch(:topic), state: quest.fetch(:state)}
      end

      # The replayed conversation (the cold-boot law): the session ledger blob
      # through the reader's sink seam — tail-capped, honest omitted count.
      # No session → nothing to replay (the blob is session-keyed).
      def transcript(session)
        return {lines: [], omitted: 0} unless session

        Kquest::Ui::BriefingTranscript.for_session(conn, session)
      end

      # The open session's still-`enqueued` turns in service order (the
      # worker's own ORDER BY seq) — rendered as queued. No session →
      # nothing is servable (PH0-CU-2; a banked session's leftovers are the
      # dead-letter mark's business, never "queued").
      def queued(session)
        return [] unless session

        conn[:briefing_turns]
          .where(session_id: session.fetch(:id), state: "enqueued")
          .order(:seq)
          .select(:id, :seq, :body, :created_at)
          .to_a
      end

      # The CLOSED operator sessions' still-`enqueued` turns (the banked
      # residue, I20 Part 7): a governor bank (bank_session!) closes the
      # session WITHOUT the dead-letter door, so these rows are reached by NO
      # door until the next sign-off (end_session!'s dead-letter UPDATE is
      # quest-keyed and catches them then). Rendered mutation-free as unsent —
      # never queued (PH0-CU-2: only an open session's rows are servable); no
      # new door, no worker change, no cap.
      def unsent(quest_id)
        conn[:briefing_turns]
          .join(:sessions, Sequel[:sessions][:id] => Sequel[:briefing_turns][:session_id])
          .where(Sequel[:sessions][:quest_id] => quest_id,
                 Sequel[:sessions][:driver] => "operator")
          .exclude(Sequel[:sessions][:ended_at] => nil)
          .where(Sequel[:briefing_turns][:state] => "enqueued")
          .order(Sequel[:briefing_turns][:seq])
          .select(Sequel[:briefing_turns][:id], Sequel[:briefing_turns][:seq],
                  Sequel[:briefing_turns][:body], Sequel[:briefing_turns][:created_at])
          .to_a
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
