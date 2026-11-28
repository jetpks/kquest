# frozen_string_literal: true

module Kquest
  class Routes < Hanami::Routes
    mount HanamiHealthcheck::Endpoint.new, at: "/up"

    # Auth — OmniAuth callback (GET for redirect, POST for form submission)
    get  "/auth/:provider/callback", to: "sessions.create"
    post "/auth/:provider/callback", to: "sessions.create"
    get  "/auth/failure",            to: "sessions.failure"

    # Logout — both GET (link) and DELETE (form)
    get    "/logout", to: "sessions.destroy"
    delete "/logout", to: "sessions.destroy"

    # The shell's root: the DASHBOARD (I08 §4 placement — "home redirects to
    # it"; I16 Part 3: anonymous users get the 200 sign-in prompt card, never
    # a redirect — `require_login → "/" → dashboard → "/"` would loop). Home
    # retires; its chassis coverage carries to Dashboard/Index.
    root to: "dashboard.index"

    # Create quest (I16 Part 3): the pre-briefing form — the ROW ONLY (no
    # session, no worker, no briefing; the interactive briefing is I17's).
    post "/quests", to: "dashboard.create_quest"

    # The workspace-admin doors (I19 Part 2): create/rename workspaces,
    # add/remove members, grant-to-workspace, grant-public, revoke — the
    # write halves of the I02 workspace/sharing model. All POST (the
    # console-door house style), all CSRF-checked by default, all
    # owner-gated (404 non-leak) through the ONE OperatorWrite door module.
    post "/workspaces",                                     to: "dashboard.create_workspace"
    post "/workspaces/:workspace_id/rename",                to: "dashboard.rename_workspace"
    post "/workspaces/:workspace_id/members",               to: "dashboard.add_workspace_member"
    post "/workspaces/:workspace_id/members/remove",        to: "dashboard.remove_workspace_member"
    post "/workspaces/:workspace_id/grants",                to: "dashboard.create_workspace_grant"
    post "/grants/public",                                  to: "dashboard.create_public_grant"
    post "/grants/:grant_id/revoke",                        to: "dashboard.revoke_grant"

    # The read-surface slices (I16): quest view + lifecycle door + cost views,
    # frontier inspector + graph browser, report view — each slice's own
    # routes carry its URL map.
    slice :quest, at: "/"
    slice :graph, at: "/"
    slice :reports, at: "/"

    # The watch slice (I15): the quest-watch stream + the /metrics exposition
    # — the slice's own routes (slices/watch/routes.rb) carry the frozen URL
    # contract for ENTRY 5 (`GET /quests/:quest_id/stream`, `GET /metrics`) +
    # the I16 additions (`/alerts`, `/alerts/stream`, `POST
    # /alerts/acknowledge`).
    slice :watch, at: "/"
  end
end
