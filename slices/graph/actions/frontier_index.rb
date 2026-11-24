# frozen_string_literal: true

module Graph
  module Actions
    # GET /quests/:quest_id/frontier — the FRONTIER INSPECTOR (I08 §4 row 3 /
    # I16 Part 5): the open/total + mass fuse reading (the law views), closure
    # classes, aging bands, the OVERHANG BADGE (CapRecords.overhang_by_surface
    # for this surface — I07 DR-05's wiring), server-side filter/sort by mass
    # decile / age / state, ALL CAPPED with "showing N of M". The hand-add
    # write is I17's (session-bearing, L13) — this surface is read-only.
    class FrontierIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        render_inertia(req, res, "Frontier/Index",
                       props: props(user, quest_id, req.params))
      end

      private

      def conn = gateway.connection

      def props(user, quest_id, params)
        listing = capped_entries(user, quest_id, params)
        {
          listing: listing,
          mass: mass_fuse(quest_id),
          closure_classes: closure_classes(quest_id),
          aging_bands: aging_bands(quest_id),
          overhang: overhang_badge(user),
          filters: filters(params)
        }
      end

      # The entries (L15): principled order (the view's own mass-fuse order or
      # the caller's sort param), the config cap, telemetry — via the ONE
      # shared helper.
      def capped_entries(user, quest_id, params)
        dataset = entries_dataset(quest_id, params)
        # The mass fuse is the default order; it exists only on the open view
        # (v_frontier_open carries mass = uncertainty * relevance).
        default_order = params[:state]&.to_s == "closed" ? :opened_at : :mass
        order = case params[:sort]&.to_s
                when "age" then [Sequel.desc(:opened_at), :entry_id]
                when "uncertainty" then [Sequel.desc(:uncertainty), :entry_id]
                when "relevance" then [Sequel.desc(:relevance), :entry_id]
                else [Sequel.desc(default_order), :entry_id]
                end
        Kquest::Ui::CappedListing.call(conn, dataset, surface: "frontier",
                                       user_id: user.id, quest_id: quest_id, order: order)
      end

      def entries_dataset(quest_id, params)
        state = params[:state]&.to_s == "closed" ? "closed" : "open"
        dataset = if state == "open"
                    conn[:v_frontier_open].where(quest_id: quest_id)
                  else
                    conn[:frontier_entries].where(quest_id: quest_id, state: "closed")
                                           .select(Sequel.lit("id AS entry_id"), :claim_id,
                                                   :need, :uncertainty, :relevance,
                                                   :opened_at, :closed_at, :closure_type)
                  end
        dataset = apply_mass_decile(dataset, quest_id, params) if state == "open"
        apply_age_filter(dataset, params)
      end

      # Mass decile (server-side): the d-th decile of the quest's mass range —
      # the rows whose mass sits in that band.
      def apply_mass_decile(dataset, quest_id, params)
        decile = Integer(params[:mass_decile].to_s, 10)
        return dataset unless decile.between?(1, 10)

        max_mass = conn[:v_frontier_open].where(quest_id: quest_id).max(:mass) || 0
        floor = (max_mass * (decile - 1)) / 10.0
        dataset.where(Sequel[:v_frontier_open][:mass] >= floor)
      rescue ArgumentError, TypeError
        dataset
      end

      def apply_age_filter(dataset, params)
        days = Integer(params[:age_days].to_s, 10)
        return dataset unless days.positive?

        dataset.where(Sequel.lit("opened_at < now() - (? || ' days')::interval", days))
      rescue ArgumentError, TypeError
        dataset
      end

      def mass_fuse(quest_id)
        row = conn[:v_frontier_mass].where(quest_id: quest_id).first
        {open_entries: row ? row.fetch(:open_entries) : 0,
         mass: row ? row.fetch(:mass) : 0}
      end

      # The closure classes (the frontier's own vocabulary): how the set
      # closed — fetch / internal / refusal — plus still-open.
      def closure_classes(quest_id)
        conn[:frontier_entries].where(quest_id: quest_id).group(:state, :closure_type)
                               .select(:state, :closure_type,
                                       Sequel.lit("count(*) AS n")).to_a
      end

      # The aging bands (the aging_open_needs shape, I07 §6): the open set by
      # age band — day-one / under-a-week / over-the-7d-band / over-a-month.
      def aging_bands(quest_id)
        scope = conn[:frontier_entries].where(quest_id: quest_id, state: "open")
        {
          "under_1d" => scope.where(Sequel.lit("now() - opened_at < interval '1 day'")).count,
          "1d_to_7d" => scope.where(Sequel.lit("now() - opened_at >= interval '1 day' AND " \
                                                "now() - opened_at < interval '7 days'")).count,
          "7d_to_30d" => scope.where(Sequel.lit("now() - opened_at >= interval '7 days' AND " \
                                                "now() - opened_at < interval '30 days'")).count,
          "over_30d" => scope.where(Sequel.lit("now() - opened_at >= interval '30 days'")).count
        }
      end

      # The OVERHANG BADGE: this surface's overhang (I07 DR-05 — "lands with
      # the SSE dashboard"; the badge is its inspector-side half).
      def overhang_badge(user)
        Kquest::Ui::CapRecords.overhang_by_surface(conn, user_id: user.id)
                              .find { |r| r[:surface] == "frontier" }
      end

      def filters(params)
        {sort: params[:sort], state: params[:state],
         mass_decile: params[:mass_decile], age_days: params[:age_days]}
      end
    end
  end
end
