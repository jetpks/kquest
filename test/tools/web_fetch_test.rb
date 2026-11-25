# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_exa_server"

# web_fetch — fetch + save through the landed FetchBody (auto-indexing in
# ONE transaction); duplicate-fetch refuses re-fetches.
class WebFetchTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/web_fetch.md", __dir__)

  def setup
    mint
    @mock = MockExaServer.new.start
    conn[:web_providers].where(name: "test-provider").delete
    conn[:web_providers].insert(name: "test-provider", base_url: @mock.url, api_key_ref: nil)
    conn[:tool_config].where(key: "tools.web_provider").delete
    conn[:tool_config].insert(key: "tools.web_provider", text_value: "test-provider",
                              provenance: "test-minted config data")
    @tool = build_tool("web_fetch")
  end

  def teardown
    super
    @mock&.stop
  end

  def test_fetch_save_registers_source_anchorable_in_the_same_session
    @mock.script([{type: :results, results: [{url: "https://example.test/page",
                                              title: "A fetched page",
                                              text: "the fetched snapshot body"}]}])
    answer = execute_tool(@tool, url: "https://example.test/page")

    source = conn[:sources].where(user_id: @user_id).first
    refute_nil source, "the sources row landed"
    assert_equal "citable", source[:role]
    assert source[:anchorable], "anchorable in the SAME session"
    membership = conn[:quest_sources].where(quest_id: @quest_id, source_id: source[:id]).first
    refute_nil membership, "the quest membership row landed in the SAME transaction"

    # the answer carries the frozen shape
    assert_match(/\Aweb_fetch: saved C\d+ \[kb:src:\w+\] "A fetched page" \d+ chars — anchorable now/, answer)
    assert_includes answer, "web_calls=1/16"
  end

  def test_duplicate_fetch_refusal_byte_matched
    @mock.script([{type: :results, results: [{url: "https://example.test/page", title: "A page",
                                              text: "body"}]}])
    execute_tool(@tool, url: "https://example.test/page")
    c_id = "C1"

    assert_refusal("web_fetch", "duplicate-fetch",
                   slots: {src: c_id, title_seg: "\"A page\" — never re-fetch"},
                   planted: [c_id]) do
      execute_tool(@tool, url: "https://example.test/page")
    end
  end

  # The landed hard-mode test, rewritten to the FIXED mode source (I20 Part
  # 5): the quest's process_config modes under the registry key
  # quest.web_call_budget — the engine_config row mint is dead.
  def test_budget_refusal_before_the_wire
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("web_fetch")

    assert_refusal("web_fetch", "budget-exceeded",
                   slots: {line: "web_calls=0/0, mode=hard"}, planted: ["mode=hard"]) do
      execute_tool(tool, url: "https://example.test/never")
    end
    assert @mock.captured_requests.empty?
  end

  # The I20 named pin (AC7): the mode source is the QUEST's process_config
  # modes (the registry key) — a hardened quest line refuses BEFORE the wire.
  def test_hard_mode_from_the_quests_process_config_refuses_before_the_wire
    conn[:quests].where(id: @quest_id).update(
      web_call_budget: 0,
      process_config: Sequel.lit("?::jsonb",
                                 JSON.generate("modes" => {"quest.web_call_budget" => "hard"}))
    )
    tool = build_tool("web_fetch")

    assert_refusal("web_fetch", "budget-exceeded",
                   slots: {line: "web_calls=0/0, mode=hard"}, planted: ["mode=hard"]) do
      execute_tool(tool, url: "https://example.test/never")
    end
    assert @mock.captured_requests.empty?, "the quest's process_config mode refuses BEFORE the wire"
  end

  # I18 (the budget predicate's extension, Grounds §4.5/§5.7): a staging
  # fetch IS a web call — the hard refusal AND the echo count on the
  # extended predicate (web_search + web_fetch + agenda_stage). Both sides:
  # the COUNT+ECHO here, the staging tool's own side in agenda_stage_test.rb.
  def test_web_call_count_and_echo_include_a_staged_agenda_fetch
    conn[:tool_calls].insert(user_id: @user_id, quest_id: @quest_id,
                             session_id: @session.fetch(:id), seq: 1, tool: "agenda_stage",
                             args: Sequel.lit("'{}'::jsonb"), result: Sequel.lit("'{}'::jsonb"),
                             ok: true)
    @mock.script([{type: :results, results: [{url: "https://example.test/staged-after",
                                              title: "S", text: "body"}]}])

    text = execute_tool(@tool, url: "https://example.test/staged-after")

    assert_includes text, "web_calls=2/16",
                    "the echo: the staged fetch + THIS fetch (used+1, the landed arithmetic)"
  end
end
