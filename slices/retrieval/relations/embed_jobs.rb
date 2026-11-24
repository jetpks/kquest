# frozen_string_literal: true

module Retrieval
  module Relations
    class EmbedJobs < Kquest::DB::Relation
      schema(:embed_jobs, infer: true, as: :embed_jobs)
    end
  end
end
