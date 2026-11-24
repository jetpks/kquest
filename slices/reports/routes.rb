# frozen_string_literal: true

module Reports
  # The reports slice's routes (I16 Part 7): the report view (+ the body-blob
  # download through the landed uploader seam). Draft/bind/flip/import-mark
  # are I17's session-bearing writes.
  class Routes < Hanami::Routes
    get "/quests/:quest_id/report",                           to: "report_show"
    get "/quests/:quest_id/report/versions/:version_seq/body", to: "report_body"
  end
end
