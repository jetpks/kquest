# frozen_string_literal: true

module Graph
  module Actions
    # GET /quests/:quest_id/graph — the GRAPH BROWSER (I08 §4 row 4 / I16
    # Part 6). Claims/evidence/edges/derivations capped; closure status per
    # claim (v_claim_closure); lineage (v_quest_lineage); the CROSS-QUEST HUB
    # tab (v_canonical_claims: the reuse rows + the type-divergence rows that
    # feed tw_hub_divergence, plus the near-dup candidates for a selected
    # node); the conflicts-ledger docket READ-ONLY (adjudication is I17's).
    #
    # Traversal is Inertia-native: the same action with ?node=<claim_id> adds
    # the node's neighborhood + derivation paths through the CANONICAL QUERY
    # SERVICES (Kquest::Queries::{Neighborhood,DerivationPaths} — the landed
    # I01 Q3/Q1 objects; never re-derive). All writes here are I17's.
    class BrowserIndex < Kquest::Action
      include Kquest::Deps["db.gateway"]

      def handle(req, res)
        user = current_user(req)
        require_login(req, res)

        quest_id = req.params[:quest_id]
        return halt_not_found(res) unless Kquest::Ui::Visibility.visible_quest?(
          conn, user_id: user.id, quest_id: quest_id
        )

        render_inertia(req, res, "Graph/Browser", props: props(user, quest_id, req.params[:node].to_s))
      end

      private

      def conn = gateway.connection

      def props(user, quest_id, node_id)
        props = {
          claims: capped(conn[:claims].where(quest_id: quest_id),
                         user, quest_id, [Sequel.asc(:quest_seq), :id]),
          evidence: capped(conn[:evidence].where(quest_id: quest_id),
                           user, quest_id, [Sequel.asc(:created_at), :id]),
          edges: capped(conn[:evidence_edges].where(quest_id: quest_id),
                        user, quest_id, [Sequel.asc(:position), :id]),
          derivations: capped(conn[:claim_derivations].where(quest_id: quest_id),
                              user, quest_id, [Sequel.asc(:created_at), :id]),
          closure: capped(conn[:v_claim_closure].where(quest_id: quest_id),
                          user, quest_id, [Sequel.asc(:quest_seq), :claim_id]),
          lineage: conn[:v_quest_lineage].where(quest_id: quest_id)
                                         .order(Sequel.asc(:depth), :ancestor_quest_id).to_a,
          hub: hub(user),
          conflicts: conflicts_docket(user, quest_id)
        }
        node_props(user, quest_id, node_id, props)
        props
      end

      def capped(dataset, user, quest_id, order)
        Kquest::Ui::CappedListing.call(conn, dataset, surface: "graph",
                                       user_id: user.id, quest_id: quest_id, order: order)
      end

      # The cross-quest hub tab: the reuse rows (a canonical text spanning
      # quests) + the type-divergence rows (exactly what tw_hub_divergence
      # reads) — over the SAME view, capped.
      def hub(user)
        view = conn[:v_canonical_claims].where(user_id: user.id)
        {
          reused: capped(view.where(Sequel.lit("quest_count > 1")), user, nil,
                         [Sequel.desc(:quest_count), :canonical_text]),
          type_divergent: capped(view.where(type_divergent: true), user, nil,
                                 [Sequel.desc(:quest_count), :canonical_text])
        }
      end

      # The near-dup designated slot's candidates for a selected node's
      # canonical text — through the landed DedupCandidates (exact leg; the
      # near leg needs a probe vector, which a read surface never mints).
      def conflicts_docket(user, quest_id)
        conflicts = capped(conn[:conflicts].where(quest_id: quest_id), user, quest_id,
                           [Sequel.desc(:created_at), :id])
        sources = conn[:conflict_sources].where(conflict_id: conflicts[:rows].map { |r| r[:id] }).to_a
        {conflicts: conflicts, sources: sources}
      end

      def node_props(user, quest_id, node_id, props)
        node = node_id.empty? ? nil : conn[:claims].where(id: node_id, quest_id: quest_id,
                                                          user_id: user.id).first
        return props unless node

        props[:node] = {
          claim: node,
          neighborhood: Kquest::Queries::Neighborhood.new(conn: conn)
                        .hood(node.fetch(:id), user_id: user.id, quest_id: quest_id),
          derivation_paths: Kquest::Queries::DerivationPaths.new(conn: conn)
                            .paths(node.fetch(:id), user_id: user.id, quest_id: quest_id,
                                   depth_cap: paths_depth_cap),
          near_dups: Kquest::Queries::DedupCandidates.new(conn: conn)
                     .candidates(user_id: user.id, text: node.fetch(:canonical_text))[:exact]
                     .map { |r| {claim_id: r.claim_id, quest_seq: r.quest_seq,
                                 terminal_type: r.terminal_type} }
        }
        props
      end

      # The paths depth cap is ECHOED from config (tools.cap_paths_depth —
      # the I05 DR-09 row), never hardcoded.
      def paths_depth_cap
        row = conn[:tool_config].where(key: "tools.cap_paths_depth").first
        row ? Integer(row.fetch(:num_value)) : 128
      end
    end
  end
end
