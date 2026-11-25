# frozen_string_literal: true

require_relative "texts_test"

# topic_questions — the I18 briefing questions carrier (the §8 amendment;
# I03 DR-14): ONE audited transaction merging `{"topic_questions": […]}` into
# the binding decompose round-1 phase's `result` jsonb with the landed merge
# shape, optionally freezing `quests.topic`; teaching refusals (audited
# ok=false) on empty/blank/non-string entries + a blank topic. NO frozen I05
# fixture — in-code canonical call + census-able error_class tokens.
class TopicQuestionsTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @tool = build_tool("topic_questions")
  end

  def phase_row
    conn[:phases].where(id: @session.fetch(:phase_id))
  end

  def result_json
    text = phase_row.get(Sequel.lit("result::text"))
    text ? JSON.parse(text) : {}
  end

  def test_records_the_questions_into_the_phases_result_carrier
    text = execute_tool(@tool, questions: ["What decays first?", "How fast?"])

    assert_includes text, "topic_questions: recorded 2 question(s)"
    assert_includes text, "1. What decays first?"
    assert_equal({"topic_questions" => ["What decays first?", "How fast?"]}, result_json,
                 "the landed merge shape: coalesce(result,'{}'::jsonb) || ?::jsonb")
  end

  def test_merge_preserves_existing_result_keys
    phase_row.update(result: Sequel.lit("?::jsonb", JSON.generate({"note" => "kept"})))
    execute_tool(@tool, questions: ["Q1"])

    assert_equal({"note" => "kept", "topic_questions" => ["Q1"]}, result_json,
                 "the merge never clobbers prior result keys")
  end

  def test_topic_freeze_updates_the_quest_in_the_same_transaction
    text = execute_tool(@tool, questions: ["Q1", "Q2"], topic: "Momentum decay")

    assert_includes text, "topic frozen: \"Momentum decay\""
    assert_equal "Momentum decay", conn[:quests].where(id: @quest_id).get(:topic)
    assert_equal({"topic_questions" => ["Q1", "Q2"]}, result_json)
  end

  def test_no_topic_key_freezes_nothing
    execute_tool(@tool, questions: ["Q1"])

    quest = conn[:quests].where(id: @quest_id).first
    assert quest.fetch(:topic).start_with?("Pipeline fixture"),
           "the topic is untouched when the key is absent"
  end

  def test_empty_or_missing_array_refuses
    error = assert_raises(Kquest::Engine::Error) { execute_tool(@tool, questions: []) }
    assert_equal "QUESTIONS-REQUIRED", error.error_class
    assert_includes error.message, "REFUSAL: QUESTIONS-REQUIRED"
    assert_includes error.message, "topic_questions questions="

    error = assert_raises(Kquest::Engine::Error) { execute_tool(@tool) }
    assert_equal "QUESTIONS-REQUIRED", error.error_class
    assert_nil result_json["topic_questions"], "the refusal preceded any write"
  end
  def test_non_string_entries_refuse
    error = assert_raises(Kquest::Engine::Error) do
      execute_tool(@tool, questions: ["ok", 42])
    end
    assert_equal "QUESTIONS-ENTRY", error.error_class
    assert_includes error.message, "every entry"
    assert_nil result_json["topic_questions"], "the refusal preceded any write"
  end

  def test_blank_entries_refuse
    error = assert_raises(Kquest::Engine::Error) { execute_tool(@tool, questions: ["  "]) }
    assert_equal "QUESTIONS-ENTRY", error.error_class
    assert_includes error.message, "blank entries"
    assert_equal({}, result_json, "the refusal preceded any write")
  end

  def test_blank_topic_refuses
    error = assert_raises(Kquest::Engine::Error) { execute_tool(@tool, questions: ["Q1"], topic: "   ") }
    assert_equal "TOPIC-BLANK", error.error_class
    assert_includes error.message, "REFUSAL: TOPIC-BLANK"
    assert_nil result_json["topic_questions"], "the refusal preceded any write"
  end

  def test_mutates_and_registers_in_the_tool_classes
    assert_equal true, @tool.mutates?
    assert_equal "TopicQuestions", Kquest::Tools::TOOL_CLASSES.fetch("topic_questions")
    assert_equal "topic_questions", @tool.name
  end
end
