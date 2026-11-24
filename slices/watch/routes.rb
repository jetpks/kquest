# frozen_string_literal: true

module Watch
  # The watch slice's routes (I15 Part 6): the quest-watch stream and the
  # /metrics exposition — the FROZEN URL contract for ENTRY 5. The slice is
  # mounted at the root by the app router (config/routes.rb).
  class Routes < Hanami::Routes
    get "/quests/:quest_id/stream", to: "quest_stream"
    get "/metrics", to: "metrics"
  end
end
