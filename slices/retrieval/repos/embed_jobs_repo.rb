# frozen_string_literal: true

module Retrieval
  module Repos
    class EmbedJobsRepo < Kquest::DB::Repo
      def by_pk(id)
        embed_jobs.by_pk(id).one
      end
    end
  end
end
