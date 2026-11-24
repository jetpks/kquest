# frozen_string_literal: true

module Quest
  module Repos
    class StopRulesRepo < Kquest::DB::Repo
      def by_pk(id)
        stop_rules.by_pk(id).one
      end
    end
  end
end
