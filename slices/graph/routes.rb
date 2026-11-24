# frozen_string_literal: true

module Graph
  # The graph slice's routes (I16 Parts 5 + 6): the frontier inspector (+ its
  # CSV snapshot) and the graph browser (+ the evidence-span return address).
  # All operator writes on these surfaces are I17's (session-bearing, L13).
  class Routes < Hanami::Routes
    get "/quests/:quest_id/frontier",                       to: "frontier_index"
    get "/quests/:quest_id/frontier.csv",                   to: "frontier_export"
    get "/quests/:quest_id/graph",                          to: "browser_index"
    get "/quests/:quest_id/graph/evidence/:evidence_id/span", to: "evidence_span"
  end
end
