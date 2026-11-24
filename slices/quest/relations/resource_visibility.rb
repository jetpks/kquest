# frozen_string_literal: true

module Quest
  module Relations
    class ResourceVisibility < Kquest::DB::Relation
      schema(:v_resource_visibility, infer: true, as: :resource_visibility)
    end
  end
end
