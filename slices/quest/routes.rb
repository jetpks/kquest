# frozen_string_literal: true

module Quest
  # The quest slice's routes (I16 Part 1 + Part 8): the quest VIEW and the
  # lifecycle door (pause is the ONLY door while running — D5), plus the cost
  # views (the spend ledger's reading surfaces; the live tail is served by the
  # watch slice). The I15 frozen URL contract (`/quests/:quest_id/stream`)
  # belongs to the watch slice's own routes — untouched here.
  #
  # The I17 additions (additive — the landed lines above stay byte-identical):
  # the steering console (the GET page + the FIVE ledgered steering doors —
  # resume/stop/restart/mute/session-end; I17 Parts 1, 2, 6) and the
  # interactive briefing (the GET page + session/agenda/questions; I17 Part
  # 3). Every write is owner-gated through the ONE OperatorWrite door.
  class Routes < Hanami::Routes
    get  "/quests/:quest_id",           to: "quest_show"
    post "/quests/:quest_id/pause",     to: "pause"
    post "/quests/:quest_id/resume",    to: "resume"
    post "/quests/:quest_id/archive",   to: "archive"
    get  "/quests/:quest_id/costs",     to: "costs_index"
    get  "/quests/:quest_id/costs.csv", to: "costs_export"

    get  "/quests/:quest_id/console",              to: "console_index"
    post "/quests/:quest_id/console/resume",       to: "console_resume"
    post "/quests/:quest_id/console/stop",         to: "console_stop"
    post "/quests/:quest_id/console/restart",      to: "console_restart"
    post "/quests/:quest_id/console/mute",         to: "console_mute"
    post "/quests/:quest_id/console/session/end",  to: "console_session_end"

    get  "/quests/:quest_id/briefing",             to: "briefing_index"
    post "/quests/:quest_id/briefing/session",     to: "briefing_session"
    post "/quests/:quest_id/briefing/agenda",      to: "briefing_agenda"
    post "/quests/:quest_id/briefing/questions",   to: "briefing_questions"
  end
end
