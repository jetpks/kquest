# frozen_string_literal: true

module Graph
  # The graph slice's routes (I16 Parts 5 + 6): the frontier inspector (+ its
  # CSV snapshot) and the graph browser (+ the evidence-span return address).
  # All operator writes on these surfaces are I17's (session-bearing, L13).
  #
  # The I17 additions (additive — the landed lines stay byte-identical): the
  # L13 session-bearing graph writes — the frontier hand-add through the
  # LANDED frontier_add tool, and the courtroom docket's conflict ledger +
  # hypothesis writes (I17 Part 4). Owner-gated through OperatorWrite.
  class Routes < Hanami::Routes
    get "/quests/:quest_id/frontier",                       to: "frontier_index"
    get "/quests/:quest_id/frontier.csv",                   to: "frontier_export"
    get "/quests/:quest_id/graph",                          to: "browser_index"
    get "/quests/:quest_id/graph/evidence/:evidence_id/span", to: "evidence_span"

    post "/quests/:quest_id/frontier/add",                            to: "frontier_add"
    post "/quests/:quest_id/graph/conflicts",                         to: "conflicts_create"
    post "/quests/:quest_id/graph/conflicts/:conflict_id/hypothesis", to: "conflict_hypothesis"
  end
end
