# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_exa_server"

# web_search — keyless-mocked (the Exa-shaped rig IS the wire); the budget
# echo on every result; hard+exhausted refuses BEFORE the wire.
class WebSearchTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/web_search.md", __dir__)

  def setup
    mint
    @mock = MockExaServer.new.start
    upsert_provider(@mock.url)
    @tool = build_tool("web_search")
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

  def test_results_carry_the_frozen_budget_echo
    @mock.script([{type: :results, results: [{url: "https://example.test/a", title: "A title",
                                              text: "some result text"}]}])
    text = execute_tool(@tool, query: "fixture query")
    assert_includes text, "\"A title\""
    assert_includes text, "web_calls=0/16"
  end

  # The landed hard-mode test, rewritten to the FIXED mode source (I20 Part
  # 5): the quest's process_config modes under the registry key
  # quest.web_call_budget — the engine_config row mint is dead.
  def test_budget_refusal_byte_matched_hard_and_exhausted
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("web_search")

    assert_refusal("web_search", "budget-exceeded",
                   slots: {line: "web_calls=0/0, mode=hard"}, planted: ["mode=hard"]) do
      execute_tool(tool, query: "fixture query")
    end
    assert @mock.captured_requests.empty?, "a hard+exhausted line refuses BEFORE the wire"
  end

  # The I20 named pin (AC7): the mode source is the QUEST's process_config
  # modes (the registry key) — a hardened quest line refuses BEFORE the wire.
  # RED before the fix (the mode source never resolved; the wire fired).
  def test_hard_mode_from_the_quests_process_config_refuses_before_the_wire
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("web_search")

    assert_refusal("web_search", "budget-exceeded",
                   slots: {line: "web_calls=0/0, mode=hard"}, planted: ["mode=hard"]) do
      execute_tool(tool, query: "fixture query")
    end
    assert @mock.captured_requests.empty?, "the quest's process_config mode refuses BEFORE the wire"
  end

  def test_missing_provider_config_is_a_loud_operational_error
    conn[:tool_config].where(key: "tools.web_provider").delete
    produced = assert_raises(Kquest::Engine::Error) { execute_tool(@tool, query: "q") }
    assert_includes produced.message, "tools.web_provider"
  end

  def test_wire_requests_captured_by_the_rig
    @mock.script([{type: :results, results: []}])
    execute_tool(@tool, query: "the query", max_results: 3)
    logged = @mock.captured_request_logs
    assert_equal 1, logged.size
    assert_equal "/search", logged[0][:path]
    assert_equal "the query", logged[0][:body]["query"]
  end

  # I18 (the budget predicate's extension, Grounds §4.5/§5.7): a staging
  # fetch IS a web call — an ok `agenda_stage` tool_calls row counts in the
  # derived predicate, and the echo reflects it. Both sides: the COUNT here,
  # the staging tool's own side in agenda_stage_test.rb.
  def test_web_call_count_includes_a_staged_agenda_fetch
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: @session.fetch(:id), seq: 1, tool: "agenda_stage",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true)
    @mock.script([{type: :results, results: []}])

    text = execute_tool(@tool, query: "fixture query")

    assert_includes text, "web_calls=1/16",
                    "the count includes the staged fetch (the extended predicate)"
  end
end
