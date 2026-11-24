# frozen_string_literal: true

module Graph
  module Actions
    # POST /quests/:quest_id/frontier/add — the FRONTIER HAND-ADD (I17 Part
    # 4 / L13: same tools, same constraints, same audit): params claim, need,
    # uncertainty, relevance through OperatorWrite.write!(tool_name:
    # "frontier_add", …) — the LANDED tool's own refusals apply VERBATIM
    # (unknown-node, score-range, frontier-re-add, duplicate-need): 422 + an
    # audited ok=false row, no entry written. Opens/reuses the operator
    # session on demand (open_session!). OWNER-gated; the inspector's read
    # surface (frontier_index) is untouched.
    class FrontierAdd < Kquest::Action
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

        # The web shape adapter: form fields arrive as strings; the landed
        # tool's score-range law (Integer 1..5) applies to their VALUES —
        # integer strings are cast, non-integer strings pass through so the
        # tool's own refusal teaches verbatim.
        outcome = Kquest::Ui::OperatorWrite.write!(
          conn, session: session, tool_name: "frontier_add",
          args: {claim: req.params[:claim].to_s, need: req.params[:need].to_s,
                 uncertainty: cast_score(req.params[:uncertainty]),
                 relevance: cast_score(req.params[:relevance])}
        )

        unless outcome.fetch(:ok)
          res.flash["alert"] = outcome.fetch(:outcome)
          halt_unprocessable(res, [outcome.fetch(:outcome)])
        end
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/frontier",
                                 notice: outcome.fetch(:outcome))
      end

      private

      def conn = gateway.connection

      def cast_score(raw)
        Integer(raw.to_s, 10)
      rescue ArgumentError, TypeError
        raw # the tool's score-range refusal teaches verbatim
      end
    end
  end
end
