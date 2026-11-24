# frozen_string_literal: true

module Quest
  module Repos
    class UsageEventsRepo < Kquest::DB::Repo
      def by_pk(id)
        usage_events.by_pk(id).one
      end
    end
  end
end
