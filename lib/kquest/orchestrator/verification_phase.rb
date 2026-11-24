# frozen_string_literal: true

require_relative "../queries/derivation_paths"
require_relative "../tools"

module Kquest
  module Orchestrator
    # The verification phase's RUNTIME behavior (I07 DR-01/DR-02, consumed
    # as-is — DR-01 ruling A: the cadence is EVERY verification phase, no
    # per-KB job). The three failure modes as the standing agenda:
    #   (a) PATH-CHECKING — Q1 derivation paths over the whole quest graph
    #       via the landed Queries::DerivationPaths + the Q1V dangling-leaf
    #       check (zero rows required; any row is a finding fixed in-phase —
    #       corrections are in-phase graph mutations);
    #   (b) THE SPOT-CHECK SAMPLE — unit = one evidence node; n from
    #       `tool_config` `verification.spot_check_n` (20); stratified across
    #       sources (no source contributes more than ⌈n/|S|⌉+1 picks) and
    #       across need bands; drawn with a RECORDED SEED — the seed + the
    #       sampled evidence ids land in the phases result JSON (the same
    #       graph + the same seed = the same sample, L14). The mechanical
    #       spot re-read: the span is proven byte-exact against the snapshot
    #       blob (L1) — a mismatch is a finding (quote-mining's measurable
    #       half);
    #   (c) CONFLICT-LEDGER REVIEW — open conflicts + resolution-hypothesis
    #       status listed as findings for the phase's attention;
    #   (d) PROVENANCE-TIER REVIEW of the corpus (the provenance ≠ truth
    #       agenda item — surfaced, never adjudicated by machinery).
    # `verification_clean` (the transition guard) = Q1V zero + every
    # spot-check finding corrected in-phase. The re-run of the binding pass
    # against the standing report version rides the landed
    # Queries::ReportBinding (consumed by report_bind's own law).
    class VerificationPhase
      # The need bands (the across-bands stratification axis): the evidence's
      # claim-side frontier mass (uncertainty×relevance of the frontier entry
      # any supported claim opened), banded low/mid/high; unlinked evidence
      # (no frontier entry) forms its own band.
      BANDS = %w[high mid low unlinked].freeze

      def initialize(conn:, quest:, phase:)
        @conn = conn
        @quest = quest
        @phase = phase
      end

      # The result hash the runner writes into `phases.result["verification"]`.
      def run
        dangling = path_check
        spot = spot_check
        {
          "q1v_dangling" => dangling,
          "spot_check" => spot,
          "conflicts" => conflict_review,
          "provenance_review" => provenance_review,
          # clean = Q1V zero + every spot-check finding corrected in-phase:
          # the findings ARE the corrections list — an empty list is a clean
          # sweep; a non-empty list is the rework-pause evidence (I06 §5).
          "clean" => dangling.empty? && spot.fetch("findings").empty?
        }
      end

      # ── (a) path-checking ───────────────────────────────────────────────

      def path_check
        Kquest::Queries::DerivationPaths.new(conn: @conn)
                                        .dangling_leaves(user_id: @quest.fetch(:user_id),
                                                         quest_id: @quest.fetch(:id))
                                        .map { |r| {claim_id: r.fetch(:dangling_claim_id).to_s,
                                                    depth: r.fetch(:depth)} }
      end

      # ── (b) the spot-check sample ───────────────────────────────────────

      def spot_check
        n = spot_check_n
        rows = @conn[:evidence].where(user_id: @quest.fetch(:user_id),
                                      quest_id: @quest.fetch(:id))
                               .order(:id)
                               .select(:id, :source_id, :span_start, :span_end,
                                       :span_text).to_a
        seed = Random.new_seed
        sampled_ids, findings = self.class.sample(rows, n: n, seed: seed,
                                                  band_of: ->(row) { band_for(row) }) do |row|
          span_exact?(row)
        end
        {"n" => n, "seed" => seed, "sampled_ids" => sampled_ids,
         "stratification" => {"sources" => rows.map { |r| r.fetch(:source_id) }.uniq.size,
                              "bands" => BANDS},
         "findings" => findings}
      end

      # The sampler, seed-first and pure: same rows + same seed = the same
      # picks (L14 applied to auditing). The seed shuffles the row order once
      # (the deterministic input), then stratification proceeds mechanically:
      # need bands round-robin first, sources round-robin WITHIN a band, the
      # GLOBAL per-source cap ⌈n/|S|⌉+1 enforced across the whole sample (a
      # source cannot double-dip through two bands). The block re-reads one
      # evidence node (the DR-02 unit) and returns true when it checks out.
      def self.sample(rows, n:, seed:, band_of:, &check)
        rng = Random.new(seed)
        rows = rows.shuffle(random: rng)
        source_cap = (n.to_f / rows.map { |r| r[:source_id] }.uniq.size).ceil + 1
        band_queues = BANDS.filter_map do |band|
          members = rows.select { |r| band_of.call(r) == band }
          [band, shuffled_by_source(members, rng)] unless members.empty?
        end
        picked = []
        per_source = Hash.new(0)
        idx = 0
        guard = 0
        max_attempts = rows.size + band_queues.size + n
        while picked.size < n && guard < max_attempts
          guard += 1
          band, queue = band_queues[idx % band_queues.size]
          idx += 1
          next if queue.nil? || queue.empty?

          candidate = take_next(queue, per_source, source_cap)
          picked << candidate.fetch(:id).to_s if candidate
        end
        findings = picked.filter_map do |id|
          row = rows.find { |r| r.fetch(:id).to_s == id }
          next if check.nil? || check.call(row)

          "evidence #{id}: the span is NOT byte-exact against the snapshot blob " \
            "(quote-mining's measurable half — correct in-phase)"
        end
        [picked, findings]
      end

      # The need band of one evidence row (the class-level form is the pure
      # unit the tests exercise; the instance form resolves the frontier mass
      # from the live graph).
      def self.band_for(row, frontier_mass:)
        case frontier_mass
        when nil then "unlinked"
        when 0...10 then "low"
        when 10...20 then "mid"
        else "high"
        end
      end

      def band_for(row)
        mass = frontier_mass_for(row.fetch(:id))
        self.class.band_for(row, frontier_mass: mass)
      end

      # The evidence's claim-side frontier mass: the max mass over the
      # frontier entries of the claims this evidence supports.
      def frontier_mass_for(evidence_id)
        @conn[:evidence_edges]
          .join(:frontier_entries,
                Sequel[:frontier_entries][:claim_id] => Sequel[:evidence_edges][:claim_id])
          .where(Sequel[:evidence_edges][:evidence_id] => evidence_id,
                 Sequel[:frontier_entries][:quest_id] => @quest.fetch(:id))
          .select(Sequel.lit("max(uncertainty * relevance) AS mass"))
          .first&.fetch(:mass)
      end

      # The per-source queues (seed-shuffled order inside each source,
      # round-robin interleaved into one band queue).
      def self.shuffled_by_source(members, rng)
        by_source = members.group_by { |r| r[:source_id] }
        queues = by_source.keys.sort_by(&:to_s).map do |sid|
          by_source.fetch(sid).shuffle(random: rng)
        end
        out = []
        until queues.all?(&:empty?)
          queues.each do |q|
            out << q.shift unless q.empty?
          end
        end
        out
      end

      def self.take_next(queue, per_source, source_cap)
        idx = queue.index { |r| per_source[r[:source_id]] < source_cap }
        return nil unless idx

        row = queue.delete_at(idx)
        per_source[row[:source_id]] += 1
        row
      end

      # The spot re-read (DR-02's unit): the span is byte-exact vs the blob
      # (read through the BlobUploader's snapshot location — the same read
      # path node_add/source_read use; L1).
      def span_exact?(row)
        source = @conn[:sources].where(id: row.fetch(:source_id)).first
        return false unless source

        location = Kquest::BlobUploader.location_for(:snapshot, user: source.fetch(:user_id),
                                                     source_urn: source.fetch(:urn))
        blob = Kquest::BlobUploader.uploaded_file(
          JSON.generate({"id" => location, "storage" => "store"})
        ).read
        blob[row.fetch(:span_start), row.fetch(:span_end) - row.fetch(:span_start)] ==
          row.fetch(:span_text)
      rescue StandardError
        false
      end

      def spot_check_n
        config = Kquest::Tools.config(@conn)
        line = config["verification.spot_check_n"]
        value = line && Kquest::Tools.config_value(config, "verification.spot_check_n")
        raise Kquest::Engine::Error,
              "the `verification.spot_check_n` config row is missing (tool_config) — the " \
              "spot-check sample cannot size itself (I07 DR-02 ruling A: n = 20)" unless value

        Integer(value)
      end

      # ── (c) conflict-ledger review ──────────────────────────────────────

      def conflict_review
        @conn[:conflicts].where(user_id: @quest.fetch(:user_id),
                                quest_id: @quest.fetch(:id)).order(:created_at).to_a
                         .map do |r|
          {conflict_id: r.fetch(:id).to_s, divergence: r.fetch(:divergence),
           resolution_hypothesis: r.fetch(:resolution_hypothesis)}
        end
      end

      # ── (d) provenance-tier review (surfaced, never adjudicated) ────────

      def provenance_review
        @conn[:quest_sources]
          .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => @quest.fetch(:id))
          .group_and_count(Sequel[:sources][:role])
          .to_h { |r| [r.fetch(:role), r.fetch(:count)] }
      end
    end
  end
end
