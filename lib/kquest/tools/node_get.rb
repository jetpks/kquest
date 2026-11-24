# frozen_string_literal: true

module Kquest
  module Tools
    # One node by K-alias or urn, with its in/out edges and field values
    # (L15: the cold-boot reconstruction's store-backed read).
    class NodeGet < Base
      tool_name "node_get"

      parameters do
        {"type" => "object",
         "properties" => {"node" => {"type" => "string"}},
         "required" => ["node"]}
      end

      def execute(**args)
        node = find_claim(args[:node].to_s)
        refuse("node_get", "unknown-node", id: args[:node].to_s) unless node

        out_edges = conn[:claim_derivations].where(claim_id: node.fetch(:id)).order(:position).to_a
        in_edges = conn[:claim_derivations].where(parent_claim_id: node.fetch(:id)).order(:position).to_a
        evidence = conn[:evidence_edges].join(:evidence, Sequel[:evidence][:id] => Sequel[:evidence_edges][:evidence_id])
                                         .where(Sequel[:evidence_edges][:claim_id] => node.fetch(:id))
                                         .select(Sequel[:evidence_edges][:relation], Sequel[:evidence][:id]).to_a

        {
          alias: claim_alias(node), urn: node.fetch(:urn), label: "claim",
          text: node.fetch(:text),
          terminal: node.fetch(:terminal_type) &&
                    {"type" => node.fetch(:terminal_type), "basis" => node.fetch(:terminal_basis)},
          derives_from: out_edges.map do |e|
            parent = conn[:claims].where(id: e.fetch(:parent_claim_id)).first
            {alias: claim_alias(parent), position: e.fetch(:position)}
          end,
          derived_from_by: in_edges.map do |e|
            child = conn[:claims].where(id: e.fetch(:claim_id)).first
            {alias: claim_alias(child), position: e.fetch(:position)}
          end,
          evidence: evidence.map { |e| "E#{evidence_ordinal(conn[:evidence].where(id: e.fetch(:id)).first)}" }
        }.to_json
      end
    end
  end
end
