# frozen_string_literal: true

module Quest
  module Relations
    class Sessions < Kquest::DB::Relation
      schema(:sessions, infer: true, as: :sessions)
    end
  end
end
