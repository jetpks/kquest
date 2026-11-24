# frozen_string_literal: true

module Reports
  module Relations
    class ReportCitations < Kquest::DB::Relation
      schema(:report_citations, infer: true, as: :report_citations)
    end
  end
end
