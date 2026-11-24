# frozen_string_literal: true

module Quest
  module Actions
    # POST /quests/:quest_id/briefing/agenda — STAGE an agenda doc (I17 Part
    # 3 / I06 §8): through the LANDED Kquest::Pipeline::FetchBody (the ONE
    # ingestion door; role `agenda` — readable, never anchorable or citable,
    # natively excluded from the decompose gate by v_unmined_sources'
    # citable filter; idem by content address — re-staging the same bytes
    # registers membership only, never a second source). KEYLESS: the
    # operator supplies the url/title/document text. Requires the open
    # briefing session (422 teaching refusal otherwise); the staged row is
    # AUDITED via OperatorWrite.record! (tool `briefing_agenda`). An invalid
    # URL is the `ck_sources_*` CHECK law TAUGHT — 422, never a 500. Every
    # halt happens OUTSIDE the transaction (res.redirect_to/halt throw
    # :halt — they never unwind through a Sequel block; the landed doors'
    # own law).
    class BriefingAgenda < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        quest = Kquest::Ui::OperatorWrite.owner_quest!(conn, user_id: user.id, quest_id: quest_id)
        return halt_not_found(res) unless quest

        session = Kquest::Ui::OperatorWrite.current_session(conn, quest_id: quest_id)
        unless session
          halt_unprocessable(res, ["no open briefing session — open one first (the briefing is " \
                                   "an interactive session; the staging is session-bearing)"])
        end

        url = req.params[:url].to_s.strip
        title = req.params[:title].to_s.strip
        text = req.params[:text].to_s
        if url.empty? || title.empty? || text.strip.empty?
          halt_unprocessable(res, ["url, title, and the document text are each required — " \
                                   "the source row is CHECK-nonempty on all three"])
        end

        # The URL check BEFORE the transaction (the same canonicalizer
        # FetchBody runs — a pure call; the CHECK law taught, never a 500).
        begin
          Kquest::Pipeline::CanonicalUrl.call(url)
        rescue Kquest::Pipeline::Error => e
          halt_unprocessable(res, [e.message])
        end

        result = nil
        conn.transaction do
          result = Kquest::Pipeline::FetchBody.call(
            user_id: user.id, url: url, title: title, role: "agenda",
            snapshot_text: text, raw_body: text,
            quest_id: quest_id, phase_id: session.fetch(:phase_id), conn: conn
          )
          Kquest::Ui::OperatorWrite.record!(
            conn, session: session, tool: "briefing_agenda",
            args: {url: url, title: title, urn: result.fetch(:urn)},
            result: {content: "staged #{result.fetch(:urn)} (created=#{result.fetch(:created)})",
                     is_error: false},
            ok: true
          )
        end

        notice = result.fetch(:created) ? "Agenda doc staged (#{result.fetch(:urn)})." : \
                   "Agenda doc already staged — content-address idem: membership registered " \
                   "(#{result.fetch(:urn)})."
        redirect_back_with_flash(req, res, fallback: "/quests/#{quest_id}/briefing", notice: notice)
      end

      private

      def conn = gateway.connection
    end
  end
end
