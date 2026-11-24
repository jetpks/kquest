# frozen_string_literal: true

module Reports
  module Relations
    class ReportVersions < Kquest::DB::Relation
      schema(:report_versions, infer: true, as: :report_versions)
    end
  end
end
