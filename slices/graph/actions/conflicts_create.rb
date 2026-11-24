# frozen_string_literal: true

module Graph
  module Actions
    # POST /quests/:quest_id/graph/conflicts — LEDGER A CONFLICT (I17 Part 4;
    # the courtroom's first act, from a tw_hub_divergence finding or the
    # operator's own cross-examination): params claim_id, divergence
    # (non-empty), hypothesis (optional), source_urns (optional list). ONE
    # transaction: the claim must be THIS quest's (the teaching refusal
    # otherwise); the sources must resolve to the operator's own citable
    # sources (the conditional-FK law, taught); the `conflicts` row + the
    # `conflict_sources` exhibit rows (source_anchorable: true — the CHECK
    # law) + the OperatorWrite.record! audit (tool `conflict_ledger`). The
    # hub is never touched (it holds no state — adjudication is in the
    # SOURCE quest). Session-bearing: opens/reuses the operator session on
    # demand; every refusal a teaching 422 with no partial write.
    class ConflictsCreate < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        session = Kquest::Ui::OperatorWrite.open_session!(
          conn, user: {id: user.id, username: user.username}, quest: quest
        )

        divergence = req.params[:divergence].to_s.strip
        if req.params[:claim_id].to_s.strip.empty? || divergence.empty?
          halt_unprocessable(res, ["a claim and a non-empty divergence are required — the " \
                                   "conflict row is the courtroom's ledger entry"])
        end

        claim = conn[:claims].where(id: req.params[:claim_id], quest_id: quest_id).first
        unless claim
          halt_unprocessable(res, ["the claim is not this quest's — adjudication is in the " \
                                   "SOURCE quest (the hub is derived and holds no state)"])
        end

        sources = resolve_sources(user.id, req.params[:source_urns])
        if sources.nil?
          halt_unprocessable(res, ["the cited sources must resolve to YOUR OWN citable sources " \
                                   "by urn (the conditional-FK law)"])
        end

        conflict_id = nil
        conn.transaction do
          conflict_id = conn[:conflicts].insert(
            user_id: user.id, quest_id: quest_id, claim_id: claim.fetch(:id),
            divergence: divergence,
            resolution_hypothesis: req.params[:hypothesis].to_s.strip.empty? ? nil : req.params[:hypothesis].to_s.strip,
            created_session_id: session.fetch(:id)
          )
          sources.each do |source|
            conn[:conflict_sources].insert(
              conflict_id: conflict_id, source_id: source.fetch(:id),
              user_id: user.id, source_anchorable: true
            )
          end
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "conflict_ledger",
            args: {claim: claim.fetch(:urn), divergence: divergence,
                   sources: sources.map { |s| s.fetch(:urn) }},
            result: {content: "conflict ledgered on #{claim.fetch(:urn)} with " \
                              "#{sources.size} exhibit(s)", is_error: false},
            ok: true
          )
        end

        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/graph",
                                 notice: "Conflict ledgered (#{conflict_id}) — hypothesize to adjudicate.")
      end

      private

      def conn = gateway.connection

      # The exhibit rows' sources: urns resolved to the operator's OWN
      # citable sources (role citable — the anchorable generated column's
      # own definition). An unresolvable urn refuses the WHOLE write (no
      # partial docket entry). nil return = teaching refusal.
      def resolve_sources(user_id, urns)
        urn_list = Array(urns).map { |u| u.to_s.strip }.reject(&:empty?)
        return [] if urn_list.empty?

        rows = conn[:sources].where(user_id: user_id, role: "citable", urn: urn_list).to_a
        rows.length == urn_list.length ? rows : nil
      end
    end
  end
end
