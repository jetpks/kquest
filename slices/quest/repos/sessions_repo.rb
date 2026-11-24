# frozen_string_literal: true

module Quest
  module Repos
    class SessionsRepo < Kquest::DB::Repo
      def by_pk(id)
        sessions.by_pk(id).one
      end
    end
  end
end
