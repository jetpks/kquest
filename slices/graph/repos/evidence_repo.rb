# frozen_string_literal: true

module Graph
  module Repos
    class EvidenceRepo < Kquest::DB::Repo
      def by_pk(id)
        evidence.by_pk(id).one
      end
    end
  end
end
