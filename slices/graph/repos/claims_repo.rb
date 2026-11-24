# frozen_string_literal: true

module Graph
  module Repos
    class ClaimsRepo < Kquest::DB::Repo
      def by_pk(id)
        claims.by_pk(id).one
      end
    end
  end
end
