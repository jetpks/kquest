# frozen_string_literal: true

require_relative "texts_test"
require_relative "../support/mock_completions_server"
require "kernel/sync"

# The tool substrate (I14 Part 3): the ordered inventory, canonical-call
# descriptions, profile resolution, and the registration-into-harness turn
# (a scripted :tool_use turn calling node_add through the landed harness
# lands the claims row + its audit row in the SAME transaction).
class RegistryTest < Minitest::Test
  include ToolRig

  FIXTURE = File.expand_path("../../design/I05-tool-surface/artifacts/fixtures/node_add.md", __dir__)

  def setup
    mint
    mint_profiles
    @mock = MockCompletionsServer.new.start
  end

  def teardown
    super
    @mock&.stop
  end

  def test_inventory_is_the_ordered_24_name_list
    assert_equal %w[node_add node_set node_get edge_add frontier_add frontier_close
                    status search list paths mass neighbors
                    source_read source_grep source_list
                    web_search web_fetch
                    retrieve
                    report_draft report_bind
                    harness quest_status subagent_spawn subagent_status],
                 Kquest::Tools::INVENTORY
  end

  def test_descriptions_open_with_the_canonical_calls
    Kquest::Tools::INVENTORY.each do |name|
      next if name == "harness" # the census name's texts are the landed ToolHarness law

      tool = build_tool(name)
      canonicals = Kquest::Tools::Texts.canonical_calls(name)
      # the description OPENS with the first canonical call and carries every
      # form (node_add's claim + evidence forms each open the description)
      assert tool.description.start_with?(canonicals.first),
             "#{name}'s description opens with its canonical call (T-CALL)"
      canonicals.each do |call|
        assert_includes tool.description, call
      end
    end
  end

  def test_harness_is_a_census_name_not_callable
    assert_raises(KeyError) { build_tool("harness") }
  end

  def test_profile_resolution_yields_the_callable_subset
    survey = Kquest::Tools.profile_tools(conn, "survey")
    assert_equal 11, survey.size
    refute_includes survey, "node_add"
    refute_includes survey, "subagent_spawn", "no recursion"
    registered = Kquest::Tools.registry(survey, conn: conn, session: @session, ledger: nil,
                                        config: default_config)
    assert_equal survey, registered.map(&:name)
  end

  def test_registration_is_the_restriction_through_the_landed_harness
    conn[:llm_providers].where(name: "registry-test-provider").delete
    conn[:llm_providers].insert(name: "registry-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "registry-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    row = conn[:llm_providers].where(name: "registry-test-provider").first
    session = {id: @session[:id], user_id: @user_id, quest_id: @quest_id,
               phase_id: @session[:phase_id], model: row[:model_id]}
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                              config: Kquest::Engine.config(conn))
    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)

    survey = Kquest::Tools.profile_tools(conn, "survey")
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
                                  .with_instructions("i")
    harness.register!(chat, tools: Kquest::Tools.registry(survey, conn: conn, session: @session,
                                                          ledger: nil, config: default_config))
    refute_includes harness.legal_names, "node_add",
                    "the registration IS the restriction (survey is read-only)"
    assert_includes harness.legal_names, "status"

    # an unregistered call lands in the unknown-tool path teaching the list
    refusal = harness.unknown_tool_refusal("node_add")
    assert_equal Kquest::Tools::Texts.refusal("harness", "unknown-tool")
                   .gsub("<name>", "node_add")
                   .gsub("<legal-tools>", harness.legal_names.join(", ")), refusal
  end

  # The headless pattern as a named test: a scripted :tool_use turn calling
  # node_add through the harness lands the claims row + its tool_calls audit
  # row in the SAME transaction (E-AUDIT/T-AUDIT).
  def test_tool_use_turn_through_the_harness_lands_claim_and_audit_in_one_transaction
    conn[:llm_providers].where(name: "registry-test-provider").delete
    conn[:llm_providers].insert(name: "registry-test-provider", base_url: @mock.url,
                                api_key_ref: nil, model_id: "registry-test-model",
                                context_window: 8192, max_tokens: 512, reasoning: false,
                                max_retries: 0)
    row = conn[:llm_providers].where(name: "registry-test-provider").first
    session = {id: @session[:id], user_id: @user_id, quest_id: @quest_id,
               phase_id: @session[:phase_id], model: row[:model_id]}
    ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
    harness = Kquest::Engine::ToolHarness.new(conn: conn, session: session, ledger: ledger,
                                              config: Kquest::Engine.config(conn))
    node_add = build_tool("node_add")

    desk = Kquest::Engine::ProviderDesk.new(conn: conn, provider_row: row, session: session)
    chat = Fast::Completions::Chat.new(client: desk.client, model: desk.model)
                                  .with_instructions("i")
    harness.register!(chat, tools: [node_add])

    @mock.script([
      {type: :tool_use, tool_calls: [{id: "c1", name: "node_add",
                                      arguments: {label: "claim", text: "a claim via the harness"}}]},
      {type: :text, content: "done"}
    ])

    Sync { chat.step }

    claim = conn[:claims].where(quest_id: @quest_id).first
    refute_nil claim, "the claims row landed"
    audit = conn[:tool_calls].where(session_id: session[:id], tool: "node_add").first
    refute_nil audit, "the audit row landed"
    assert audit[:ok]
  end
end
