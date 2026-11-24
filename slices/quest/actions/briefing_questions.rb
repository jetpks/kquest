# frozen_string_literal: true

require "json"

module Quest
  module Actions
    # POST /quests/:quest_id/briefing/questions — WRITE the topic questions
    # (I17 Part 3): merge `{"topic_questions": [<non-empty strings>, …]}`
    # into the binding decompose phase's `result` jsonb (the I03 DR-14
    # carrier — the landed `coalesce(result, '{}'::jsonb) || ?::jsonb` merge
    # shape), in the SAME transaction as the optional TOPIC FREEZE (an
    # optional `topic` param updates `quests.topic` — recorded) and the
    # `OperatorWrite.record!` audit row (tool `briefing_questions`). Requires
    # the open session; empty question lists / blank strings refuse 422
    # (teaching). This is the ONLY direct `[:phases]` write any UI action
    # makes (AC4's allow-list names THIS file).
    class BriefingQuestions < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: quest_id)
        unless session
          halt_unprocessable(res, ["no open briefing session — open one first (the topic " \
                                   "questions are the session-bearing carrier write)"])
        end

        questions = Array(req.params[:questions]).map { |q| q.to_s.strip }.reject(&:empty?)
        if questions.empty? || questions.length != Array(req.params[:questions]).length
          halt_unprocessable(res, ["the questions are non-empty strings — an empty list or a " \
                                   "blank entry teaches the form, it never writes"])
        end

        binding_phase = conn[:phases].where(id: session.fetch(:phase_id)).first
        halt_unprocessable(res, ["the binding phase row is missing — the session's phase is the " \
                                 "carrier"]) unless binding_phase

        topic_change = nil
        proposed_topic = req.params[:topic].to_s.strip
        topic_change = [quest.fetch(:topic), proposed_topic] if !proposed_topic.empty? &&
                                                               proposed_topic != quest.fetch(:topic)

        conn.transaction do
          conn[:phases].where(id: binding_phase.fetch(:id)).update(
            result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                               JSON.generate("topic_questions" => questions))
          )
          if topic_change
            conn[:quests].where(id: quest_id).update(topic: topic_change[1])
          end
          args = {questions: questions, phase: binding_phase.fetch(:id)}
          args[:topic] = "#{topic_change[0]}→#{topic_change[1]}" if topic_change
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "briefing_questions", args: args,
            result: {content: "#{questions.size} topic question(s) recorded" +
                              (topic_change ? " — topic frozen: #{topic_change[1]}" : ""),
                     is_error: false},
            ok: true
          )
        end

        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/briefing",
                                 notice: "Topic questions recorded — the sign-off ends the " \
                                         "session (the agenda_staged gate hands autonomy).")
      end

      private

      def conn = gateway.connection
    end
  end
end
