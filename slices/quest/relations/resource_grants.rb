# frozen_string_literal: true

module Quest
  module Relations
    class ResourceGrants < Kquest::DB::Relation
      schema(:resource_grants, infer: true, as: :resource_grants)
    end
  end
end
