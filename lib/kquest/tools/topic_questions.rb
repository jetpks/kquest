# frozen_string_literal: true

require "json"

module Kquest
  module Tools
    # Record the briefing's topic questions (I18 the §8 amendment — the
    # AGENT's write, steered conversationally): merge
    # `{"topic_questions": […]}` into the binding decompose round-1 phase's
    # `result` jsonb (the I03 DR-14 carrier — the ground truth the
    # mechanical relevance embeds need-texts against) with the landed merge
    # shape, and when `topic` is given also update `quests.topic` (the
    # recorded topic freeze — now the agent's write). BOTH writes ride the
    # harness's ONE audited transaction (the harness-owned Sequel
    # transaction the tool's writes join — I01 §3.15).
    #
    # NO frozen I05 fixture (the Grounds law): in-code canonical-call
    # description (the T-CALL shape) + teaching refusals raised as
    # `Kquest::Engine::Error` with the census-able rule-id token as
    # `error_class` — audited ok=false through the standard harness path.
    class TopicQuestions < Base
      tool_name "topic_questions"

      CANONICAL_CALL = 'topic_questions questions=["…", "…"] topic="…"'.freeze

      DESCRIPTION = <<~DESC.freeze
        ```#{CANONICAL_CALL}``` — record the briefing's topic questions (and
        optionally freeze the topic) as the outcome of this conversation.
        `questions` is REQUIRED: a non-empty array of non-empty strings — the
        questions the decompose round will answer. `topic` is optional: when
        given it freezes the quest's topic. Both land in the binding phase's
        durable record (phases.result) in ONE audited write.
      DESC

      parameters do
        {"type" => "object",
         "properties" => {"questions" => {"type" => "array",
                                          "items" => {"type" => "string"}},
                          "topic" => {"type" => "string"}},
         "required" => ["questions"]}
      end

      def description = DESCRIPTION

      def mutates? = true

      def execute(**args)
        questions = checked_questions!(args[:questions])
        topic = checked_topic!(args[:topic])

        merged = JSON.generate({"topic_questions" => questions})
        conn[:phases].where(id: phase_id)
                     .update(result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb", merged))
        topic_line = " — the carrier is the binding phase's phases.result"
        if topic
          conn[:quests].where(id: quest_id).update(topic: topic)
          topic_line = " — topic frozen: \"#{topic}\" (the carrier is the binding phase's phases.result)"
        end

        numbered = questions.each_with_index.map { |q, i| "#{i + 1}. #{q}" }.join("\n")
        "topic_questions: recorded #{questions.size} question(s)#{topic_line}\n#{numbered}"
      end

      private

      # The teaching refusals (422-class, audited ok=false): a missing or
      # empty array, non-string entries, blank entries; a blank topic.
      def checked_questions!(raw)
        unless raw.is_a?(Array) && !raw.empty?
          raise Kquest::Engine::Error.new(
            "REFUSAL: QUESTIONS-REQUIRED: `questions` must be a non-empty array of non-empty " \
            "strings — #{CANONICAL_CALL}; the topic questions are the decompose round's ground " \
            "truth and are recorded only through this tool",
            error_class: "QUESTIONS-REQUIRED"
          )
        end
        unless raw.all? { |q| q.is_a?(String) }
          raise Kquest::Engine::Error.new(
            "REFUSAL: QUESTIONS-ENTRY: every entry of `questions` must be a non-empty STRING — " \
            "#{CANONICAL_CALL} (one question per entry, in the operator's own words)",
            error_class: "QUESTIONS-ENTRY"
          )
        end
        unless raw.all? { |q| !q.strip.empty? }
          raise Kquest::Engine::Error.new(
            "REFUSAL: QUESTIONS-ENTRY: every entry of `questions` must be a non-empty STRING — " \
            "#{CANONICAL_CALL} (blank entries record nothing; drop them or write the question)",
            error_class: "QUESTIONS-ENTRY"
          )
        end
        raw
      end

      def checked_topic!(raw)
        topic = raw.to_s
        if raw && topic.strip.empty?
          raise Kquest::Engine::Error.new(
            "REFUSAL: TOPIC-BLANK: a blank `topic` freezes nothing — omit the key entirely or " \
            "carry the agreed topic text (#{CANONICAL_CALL})",
            error_class: "TOPIC-BLANK"
          )
        end
        topic.strip.empty? ? nil : topic
      end
    end
  end
end
