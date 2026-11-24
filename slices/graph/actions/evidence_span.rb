# frozen_string_literal: true

module Graph
  module Actions
    # GET /quests/:quest_id/graph/evidence/:evidence_id/span — the evidence's
    # RETURN ADDRESS (I16 Part 6): the pinned snapshot slice at the evidence's
    # offsets, read through the landed BlobUploader reconstitution
    # (location_for(:snapshot, ...) — the STORE address; the DB column's
    # snapshot bookkeeping is the CHECK law, not the layout) and BYTE-PINNED
    # against sources.snapshot_char_count: a pin mismatch is a loud 422, never
    # a silently shifted slice. Visibility-gated; JSON, not an Inertia page.
    class EvidenceSpan < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        evidence = conn[:evidence].where(id: req.params[:evidence_id],
                                         quest_id: quest_id, user_id: user.id).first
        return halt_not_found(res) unless evidence

        source = conn[:sources].where(id: evidence.fetch(:source_id),
                                      user_id: user.id).first
        return halt_not_found(res) unless source

        render_span(res, evidence, source)
      end

      private

      def conn = gateway.connection

      def render_span(res, evidence, source)
        snapshot = Kquest::BlobUploader.uploaded_file(
          JSON.generate({"id" => Kquest::BlobUploader.location_for(
            :snapshot, user: source.fetch(:user_id), source_urn: source.fetch(:urn)
          ), "storage" => "store"})
        ).read

        start = evidence.fetch(:span_start)
        finish = evidence.fetch(:span_end)
        return halt_unprocessable(
          res, ["snapshot pin broken: evidence #{evidence.fetch(:id)} pins " \
                "#{evidence.fetch(:snapshot_char_count)} chars but the store's " \
                "snapshot for #{source.fetch(:urn)} is #{snapshot.length}"]
        ) if snapshot.length != evidence.fetch(:snapshot_char_count)

        render_json(res, {
                    evidence_id: evidence.fetch(:id), source_urn: source.fetch(:urn),
                    span_start: start, span_end: finish, reading: evidence.fetch(:reading),
                    snapshot_char_count: evidence.fetch(:snapshot_char_count),
                    span_text: snapshot[start, finish - start],
                    verified: true
                  })
      end
    end
  end
end
