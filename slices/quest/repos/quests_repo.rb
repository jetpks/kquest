# frozen_string_literal: true

module Quest
  module Repos
    class QuestsRepo < Kquest::DB::Repo
      def by_pk(id)
        quests.by_pk(id).one
      end
    end
  end
end
