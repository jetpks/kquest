# frozen_string_literal: true

module Quest
  # The quest slice's routes (I16 Part 1 + Part 8): the quest VIEW and the
  # lifecycle door (pause is the ONLY door while running — D5), plus the cost
  # views (the spend ledger's reading surfaces; the live tail is served by the
  # watch slice). The I15 frozen URL contract (`/quests/:quest_id/stream`)
  # belongs to the watch slice's own routes — untouched here.
  class Routes < Hanami::Routes
    get  "/quests/:quest_id",           to: "quest_show"
    post "/quests/:quest_id/pause",     to: "pause"
    post "/quests/:quest_id/resume",    to: "resume"
    post "/quests/:quest_id/archive",   to: "archive"
    get  "/quests/:quest_id/costs",     to: "costs_index"
    get  "/quests/:quest_id/costs.csv", to: "costs_export"
  end
end
