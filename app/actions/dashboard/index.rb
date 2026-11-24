# frozen_string_literal: true

module Kquest
  module Actions
    module Dashboard
      # The DASHBOARD — the root landing surface (I08 §4 row 1, I16 Part 3;
      # `root to: "dashboard.index"` — the placement law: "home redirects to
      # it"; Home/Index retires and its chassis coverage carries here).
      #
      # Anonymous → a 200 SIGN-IN PROMPT CARD, NEVER a redirect: require_login
      # redirects to "/", and "/" is this dashboard — a blind redirect would
      # loop (`require_login → "/" → dashboard → "/"`). The Nav's GitHub
      # button is the only auth door (Grounds §8).
      #
      # Signed-in → quest cards (capped, L15), the BLIND-SPOT panel (I07 §6:
      # the four Metrics blind-spot rows + the capped_listing_overhang join
      # from CapRecords.overhang_by_surface, per I08 §4 "joins when §2.5
      # telemetry lands"), the honesty-bounds ladder (static text on the
      # page), and workspace-admin reads (render-only; the grant UI is
      # I17's). The live quest cards feed off the user-level stream — the
      # EventFeed component mounts on /alerts/stream.
      class Index < Kquest::Action
        include Kquest::Deps["db.gateway"]

        BLIND_SPOT_FAMILIES = %w[kquest_unmined_citable kquest_fetched_never_cited
                                 kquest_uncited_claims kquest_aging_open_needs].freeze

        def handle(req, res)
          user = current_user(req)
          unless user
            # 200, never a redirect — the loop hazard (Grounds §8).
            return render_inertia(req, res, "Dashboard/Index", props: {})
          end

          render_inertia(req, res, "Dashboard/Index", props: props(user))
        end

        private

        def conn = gateway.connection

        def props(user)
          {
            quests: capped_quests(user),
            blind_spots: blind_spots(user),
            overhang: Kquest::Ui::CapRecords.overhang_by_surface(conn, user_id: user.id),
            workspaces: workspace_admin_reads(user),
            stream_url: "/alerts/stream"
          }
        end

        # The user's quests (L15): state-grouped, most-recent lifecycle
        # activity first — a principled deterministic order, never silent
        # truncation (the page renders "showing N of M" from the result).
        def capped_quests(user)
          dataset = conn[:quests].where(user_id: user.id)
                                 .select_append(Sequel.lit(
                                   "(SELECT max(occurred_at) FROM quest_lifecycle_events " \
                                   "WHERE quest_id = quests.id) AS last_activity"
                                 ))
          state_group = Sequel.case({"active" => 1, "paused" => 2, "complete" => 3,
                                     "stopped" => 4, "archived" => 5}, 9,
                                    Sequel[:quests][:state])
          Kquest::Ui::CappedListing.call(
            conn, dataset, surface: "dashboard", user_id: user.id,
            order: [Sequel.asc(state_group), Sequel.desc(:last_activity), :id]
          )
        end

        # The blind-spot panel (I07 §6/DR-05): the REUSED Metrics families +
        # the overhang join (CapRecords.overhang_by_surface) — one rollup, no
        # second validator.
        def blind_spots(user)
          Kquest::Orchestrator::Metrics.families(conn, user_id: user.id)
                                       .select { |f| BLIND_SPOT_FAMILIES.include?(f[:name]) }
        end

        # Workspace-admin READS (I02): the user's owned workspaces, their
        # memberships, and the grants they issued — render-only.
        def workspace_admin_reads(user)
          workspaces = conn[:workspaces].where(created_by_user_id: user.id)
                                        .order(Sequel.asc(:created_at), :id).to_a
          memberships = conn[:workspace_members].where(user_id: user.id)
                                                .order(:workspace_id).to_a
          grants = conn[:resource_grants].where(owner_user_id: user.id)
                                         .order(Sequel.desc(:granted_at), :id).limit(50).to_a
          {workspaces: workspaces, memberships: memberships, grants: grants}
        end
      end
    end
  end
end
