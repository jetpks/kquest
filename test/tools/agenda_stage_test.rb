# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_exa_server"

# agenda_stage — the I18 briefing staging tool (the §8 amendment): a
# budget-checked wire fetch through the SAME wire the web tools use, staged
# through the ONE ingestion door with role `agenda`; the answer carries the
# staged shape + the readable-never-anchorable teaching line + the budget
# echo on the EXTENDED predicate (the count includes the staging fetch).
# Keyless-mocked (the Exa-shaped rig IS the wire); NO frozen I05 fixture —
# the description is the in-code canonical call and the refusals are
# in-code teaching refusals with census-able error_class tokens.
class AgendaStageTest < Minitest::Test
  include ToolRig

  def setup
    mint
    @mock = MockExaServer.new.start
    upsert_provider(@mock.url)
    @tool = build_tool("agenda_stage")
  end

  def teardown
    super
    @mock&.stop
  end

  def upsert_provider(base_url)
    conn[:web_providers].where(name: "test-provider").delete
    conn[:web_providers].insert(name: "test-provider", base_url: base_url, api_key_ref: nil)
    conn[:tool_config].where(key: "tools.web_provider").delete
    conn[:tool_config].insert(key: "tools.web_provider", text_value: "test-provider",
                              provenance: "test-minted config data")
  end

  def test_description_opens_with_the_in_code_canonical_call
    assert @tool.description.include?("agenda_stage url="),
           "the T-CALL shape: the description opens with the canonical call"
    assert_equal "agenda_stage", @tool.name
  end

  def test_stages_a_role_agenda_source_through_the_ingestion_door
    @mock.script([{type: :results,
                   results: [{url: "https://example.test/primer",
                              title: "The fixture primer", text: "primer body " * 20}]}])

    text = execute_tool(@tool, url: "https://example.test/primer")

    assert_includes text, "agenda_stage: staged kb:src:"
    assert_includes text, "\"The fixture primer\""
    assert_includes text, "chars"
    assert_includes text, "never anchorable or citable", "the answer text says the I06 §8 law"
    assert_includes text, "web_calls=", "the budget echo rides the answer"
    source = conn[:sources].where(role: "agenda").first
    refute_nil source, "a role-agenda source exists (content-addressed)"
    assert_equal "The fixture primer", source.fetch(:title)
    assert source.fetch(:urn).start_with?("kb:src:")
    assert conn[:quest_sources].where(quest_id: @quest_id, source_id: source.fetch(:id)).first,
           "the quest membership registered"
    blob = conn[:sources].where(id: source.fetch(:id)).get(:snapshot_char_count)
    assert_operator blob, :>, 0
  end

  def test_re_staging_registers_membership_only_never_a_second_source
    @mock.script([{type: :results, results: [{url: "https://example.test/p", title: "P",
                                              text: "same bytes"}]},
                  {type: :results, results: [{url: "https://example.test/p", title: "P",
                                              text: "same bytes"}]}])
    execute_tool(@tool, url: "https://example.test/p")
    again = execute_tool(@tool, url: "https://example.test/p")

    assert_equal 1, conn[:sources].where(role: "agenda").count, "idem by content address"
    assert_includes again, "already staged", "the idem truth is in the answer"
  end

  def test_explicit_title_wins_over_the_page_title
    @mock.script([{type: :results, results: [{url: "https://example.test/t", title: "Wire Title",
                                              text: "body"}]}])
    text = execute_tool(@tool, url: "https://example.test/t", title: "Operator's Name")

    assert_includes text, "\"Operator's Name\""
    assert_equal "Operator's Name", conn[:sources].where(role: "agenda").get(:title)
  end

  def test_blank_url_is_a_teaching_refusal_with_the_census_token
    error = assert_raises(Kquest::Engine::Error) { execute_tool(@tool, url: "  ") }
    assert_equal "AGENDA-URL-REQUIRED", error.error_class
    assert_includes error.message, "REFUSAL: AGENDA-URL-REQUIRED"
    assert_includes error.message, "agenda_stage url=", "the refusal teaches the canonical call"
    assert_empty @mock.captured_requests, "the refusal precedes the wire"
    assert_empty conn[:tool_calls].where(tool: "agenda_stage").to_a
  end

  # The landed hard-mode test, rewritten to the FIXED mode source (I20 Part
  # 5): the quest's process_config modes under the registry key
  # quest.web_call_budget — the engine_config row mint is dead.
  def test_budget_refusal_hard_and_exhausted_before_the_wire
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("agenda_stage")

    error = assert_raises(Kquest::Engine::Error) { execute_tool(tool, url: "https://example.test/x") }
    assert_equal "BUDGET-EXCEEDED", error.error_class
    assert_includes error.message, "web_calls=0/0, mode=hard"
    assert_empty @mock.captured_requests, "hard+exhausted refuses BEFORE the wire"
  end

  # The I20 named pin (AC7): the mode source is the QUEST's process_config
  # modes (the registry key) — a hardened quest line refuses BEFORE the wire.
  def test_hard_mode_from_the_quests_process_config_refuses_before_the_wire
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("agenda_stage")

    error = assert_raises(Kquest::Engine::Error) { execute_tool(tool, url: "https://example.test/x") }
    assert_equal "BUDGET-EXCEEDED", error.error_class
    assert_includes error.message, "web_calls=0/0, mode=hard"
    assert_empty @mock.captured_requests, "the quest's process_config mode refuses BEFORE the wire"
  end

  def test_budget_echo_counts_on_the_extended_predicate
    # A prior ok tool_calls row under the staging tool's OWN name counts
    # (the extended predicate: web_search + web_fetch + agenda_stage).
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: @session.fetch(:id), seq: 1, tool: "agenda_stage",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: @session.fetch(:id), seq: 2, tool: "web_search",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true)
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: @session.fetch(:id), seq: 3, tool: "web_search",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: false, error_class: "BudgetExceeded") # refused: no wire call — never counts
    @mock.script([{type: :results, results: [{url: "https://example.test/e", title: "E",
                                              text: "text"}]}])

    text = execute_tool(@tool, url: "https://example.test/e")

    assert_includes text, "web_calls=3/16",
                    "the echo: 2 prior ok web-class calls + THIS staging fetch (used+1, the " \
                    "web_fetch arithmetic)"
  end
end
