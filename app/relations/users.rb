# frozen_string_literal: true

module Kquest
  module Relations
    class Users < Kquest::DB::Relation
      schema(:users, infer: true)
    end
  end
end
