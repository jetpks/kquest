# frozen_string_literal: true

module Graph
  module Relations
    class QuestGraphFingerprint < Kquest::DB::Relation
      schema(:v_quest_graph_fingerprint, infer: true, as: :quest_graph_fingerprint)
    end
  end
end
