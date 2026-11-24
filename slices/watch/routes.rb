# frozen_string_literal: true

module Watch
  # The watch slice's routes (I15 Part 6): the quest-watch stream and the
  # /metrics exposition — the FROZEN URL contract for ENTRY 5. The slice is
  # mounted at the root by the app router (config/routes.rb).
  class Routes < Hanami::Routes
    get "/quests/:quest_id/stream", to: "quest_stream"
    get "/metrics", to: "metrics"

    # I16 Part 2 + Part 4 (additive — the frozen I15 lines above are the
    # contract and stay byte-identical): the alerting surface over the 13
    # tw_* views, the USER-level SSE serving action (the I15 producer's
    # missing server), and the flash-only acknowledge (UI state, never a
    # system state).
    get  "/alerts",           to: "alerts_index"
    get  "/alerts/stream",    to: "user_stream"
    post "/alerts/acknowledge", to: "alerts_acknowledge"
  end
end
