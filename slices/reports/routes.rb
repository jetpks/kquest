# frozen_string_literal: true

module Reports
  # The reports slice's routes (I16 Part 7): the report view (+ the body-blob
  # download through the landed uploader seam). Draft/bind/flip/import-mark
  # are I17's session-bearing writes.
  #
  # The I17 additions (additive — the landed lines stay byte-identical): the
  # L13 report writes — the draft/bind through the LANDED tools, the standing
  # flip (I02 §7's ENTRY 5 transaction), and the EXPLICIT import mark (I02
  # §3.4/§9). Owner-gated through OperatorWrite.
  class Routes < Hanami::Routes
    get "/quests/:quest_id/report",                           to: "report_show"
    get "/quests/:quest_id/report/versions/:version_seq/body", to: "report_body"

    post "/quests/:quest_id/report/draft",                                        to: "report_draft"
    post "/quests/:quest_id/report/bind",                                         to: "report_bind"
    post "/quests/:quest_id/report/versions/:version_seq/flip",                   to: "report_flip"
    post "/quests/:quest_id/report/versions/:version_seq/citations/:ordinal/import", to: "report_import_mark"
  end
end
