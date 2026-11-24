# frozen_string_literal: true

module Reports
  module Repos
    class ReportVersionsRepo < Kquest::DB::Repo
      def by_pk(id)
        report_versions.by_pk(id).one
      end
    end
  end
end
