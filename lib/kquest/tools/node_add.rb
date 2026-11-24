# frozen_string_literal: true

module Kquest
  module Tools
    # Fused creation (I05 §2/§3.1): a claim, an evidence span, or evidence +
    # its claims atomically (`supports_new`). Runs the dedup candidate check
    # BEFORE the write (exact → refuse, near → the frozen note, never a
    # refusal); stamps urns (never supplied); the span is proven byte-present
    # in the snapshot blob BEFORE any write — a refusal creates nothing
    # (L1/L5/L6, R-036). K-alias minting: quest_seq = max+1 (tool-time,
    # uq_bites). After a successful claim creation the tool mints the
    # quest-level idem-keyed claim embed job so the near leg's vectors exist.
    class NodeAdd < Base
      tool_name "node_add"

      parameters do
        {"type" => "object",
         "properties" => {
           "label" => {"type" => "string", "enum" => %w[claim evidence]},
           "text" => {"type" => "string"},
           "terminal" => {},
           "src" => {"type" => "string"},
           "span" => {"type" => "string"},
           "span_start" => {"type" => "integer"},
           "span_end" => {"type" => "integer"},
           "reading" => {"type" => "string"},
           "supports_new" => {},
           "supports" => {}
         },
         "required" => ["label"]}
      end

      def mutates? = true

      def execute(**args)
        coerced = []
        # The boundary rule parses ONCE; the detection runs on the ORIGINAL
        # value (the rehash below replaces the string with the parsed object).
        %i[terminal supports_new supports].each do |key|
          next unless args.key?(key)

          next unless Fields.coerced?(args[key])

          coerced << {terminal: "terminal:string→object",
                      supports_new: "supports_new:string→array",
                      supports: "supports:string→array"}[key]
          args[key] = Fields.coerce(args[key])
        end

        case args[:label]
        when "claim" then claim_add(args, coerced)
        when "evidence" then evidence_add(args, coerced)
        else raise ArgumentError, "node_add label must be 'claim' or 'evidence', got #{args[:label].inspect}"
        end
      end

      private

      # ── the claim form ──────────────────────────────────────────────────

      def claim_add(args, coerced)
        flat, nested, _ = Fields.partition("node_add", args)
        unknown = (flat.keys | nested.keys) - [:text, :terminal]
        refuse("node_add", "unknown-field",
               named: "UNKNOWN-FIELD: #{unknown.first} is not",
               of: "is not a field of claim",
               legal: "legal fields: #{Fields::LEGAL_FIELDS.fetch('claim').join(', ')}") if unknown.any?

        text = flat[:text] || nested[:text]
        raise ArgumentError, "node_add label=claim requires text" unless text.is_a?(String) && !text.strip.empty?

        terminal = flat[:terminal] || nested[:terminal]
        validate_terminal!(terminal)

        # The fused-form DIRECTION is fixed structurally (§4): evidence-side
        # fusion is canonical; a claim-side call cannot name its own evidence.
        refuse("node_add", "fused-direction") if args.key?(:supports_new)

        # The dedup candidate check runs BEFORE the write (R-036/I05 DR-07).
        # An EXACT duplicate in THIS quest refuses (the uq_claims_quest_
        # canonical law — cross-quest exact coexistence is the hub's law);
        # near-dups NEVER refuse — they surface the frozen note.
        candidates = check_dedup(text, [terminal].compact)
        if candidates[:exact].any? { |r| r.quest_id == quest_id }
          existing = candidates[:exact].find { |r| r.quest_id == quest_id }
          refuse("node_add", "duplicate-label", existing: "K#{existing.quest_seq}")
        end
        seq = (conn[:claims].where(quest_id: quest_id).max(:quest_seq) || 0) + 1
        canonical = canonicalize(text)
        claim_id = conn[:claims].insert(
          user_id: user_id, quest_id: quest_id, quest_seq: seq, text: text,
          terminal_type: terminal && terminal["type"], terminal_basis: terminal && terminal["basis"],
          urn: mint_claim_urn(canonical), created_session_id: session.fetch(:id)
        )
        mint_claim_embed_job!

        notes = []
        notes << bare_note unless terminal
        notes << unreferenced_note
        notes.concat(candiate_notes(candidates))
        notes.concat(coerced.map { |w| coercion_note(w) })
        "K#{seq} created #{notes.join(' ')}".strip
      end

      def validate_terminal!(terminal)
        return if terminal.nil?

        unless terminal.is_a?(Hash) &&
               %w[definitional-mathematical primary-empirical residual-uncertainty].include?(terminal["type"]) &&
               terminal["basis"].is_a?(String) && !terminal["basis"].strip.empty?
          refuse("node_add", "terminal-shape")
        end
      end

      def claim_alias_struct(row)
        # The refusal names the existing claim's K-alias (refusal-locates: the
        # model attaches evidence instead of re-adding).
        "K#{row.quest_seq}"
      end

      # ── the evidence form (fused, the default) ──────────────────────────

      def evidence_add(args, coerced)
        flat, nested, _ = Fields.partition("node_add", args)
        unknown = (flat.keys | nested.keys) -
                  [:src, :span, :span_start, :span_end, :reading, :supports, :text, :terminal]
        if unknown.any?
          refuse("node_add", "unknown-field",
                 named: "UNKNOWN-FIELD: #{unknown.first} is not",
                 of: "is not a field of evidence",
                 legal: "legal fields: #{Fields::LEGAL_FIELDS.fetch('evidence').join(', ')}")
        end

        src_ref = flat[:src] || nested[:src]
        span = flat[:span] || nested[:span]
        reading = flat[:reading] || nested[:reading]
        has_offsets = (flat[:span_start] || nested[:span_start]) && (flat[:span_end] || nested[:span_end])
        unless src_ref && reading && (span || has_offsets)
          raise ArgumentError, "node_add label=evidence requires src, span (or offsets), reading"
        end

        source = Kquest::Queries.resolve_source(conn, user_id: user_id, quest_id: quest_id, ref: src_ref.to_s)
        unless source
          raise Kquest::Engine::Error.new(
            Texts.refusal("source_read", "unknown-source", src: src_ref.to_s),
            error_class: "UNKNOWN-SOURCE"
          )
        end
        refuse("node_add", "agenda-source", src: src_ref.to_s) unless source.fetch(:anchorable)

        # Fused claims are validated BEFORE any write (a refusal creates
        # nothing); claim-side supports_new is the refused inverse direction.
        # supports_new/supports are STRUCTURAL keys (the fusion trigger) —
        # they ride the call's top level, never the field partition. A
        # plain-string edge value is refused (T5 — never silently Array()ed).
        fused = validate_fused!(args[:supports_new])
        supports = args[:supports] || []
        if supports.is_a?(String)
          refuse("node_add", "fused-shape")
        end

        snapshot = read_snapshot(source)
        span_start, span_end = locate_span!(span, source, snapshot, flat, nested)

        # duplicate-span: the uq_evidence_quest_span law, located (the
        # existing evidence's E-id + its source).
        if (dup = conn[:evidence].where(quest_id: quest_id, source_id: source.fetch(:id),
                                        span_start: span_start, span_end: span_end).first)
          refuse("node_add", "duplicate-span",
                 located: "E#{evidence_ordinal(dup)} on #{src_ref}")
        end

        # ── the write: evidence + fused claims + edges, one call ──────────
        evidence_id = conn[:evidence].insert(
          user_id: user_id, quest_id: quest_id, source_id: source.fetch(:id),
          source_anchorable: source.fetch(:anchorable),
          snapshot_char_count: source.fetch(:snapshot_char_count),
          span_start: span_start, span_end: span_end, span_text: span, reading: reading,
          created_session_id: session.fetch(:id)
        )

        created = []
        new_claims = Array(fused).map do |entry|
          terminal = entry.is_a?(Hash) ? entry["terminal"] : nil
          validate_terminal!(terminal)
          text = entry.is_a?(Hash) ? entry["text"] : entry
          seq = (conn[:claims].where(quest_id: quest_id).max(:quest_seq) || 0) + 1
          cid = conn[:claims].insert(
            user_id: user_id, quest_id: quest_id, quest_seq: seq, text: text,
            terminal_type: terminal && terminal["type"], terminal_basis: terminal && terminal["basis"],
            urn: mint_claim_urn(canonicalize(text)), created_session_id: session.fetch(:id)
          )
          created << "K#{seq}"
          [cid, seq]
        end

        wired_rows = Array(supports).map { |ref| find_claim(ref.to_s) }.compact
        target_ids = new_claims.map { |cid, _| cid } + wired_rows.map { |r| r.fetch(:id) }
        target_ids.each do |cid|
          position = (conn[:evidence_edges].where(evidence_id: evidence_id).max(:position) || 0) + 1
          conn[:evidence_edges].insert(
            user_id: user_id, quest_id: quest_id, evidence_id: evidence_id,
            relation: "supports", claim_id: cid, position: position
          )
        end
        mint_claim_embed_job!

        notes = []
        notes << dedup_note(rendered_candidates(check_dedup_for_fused(fused))) if fused&.any?
        notes.concat(coerced.map { |w| coercion_note(w) })
        e_id = "E#{evidence_ordinal(conn[:evidence].where(id: evidence_id).first)}"
        answer = "#{e_id} created on #{src_ref}" +
                 (created.any? ? " claims #{created.join(',')}" : "") +
                 (wired_rows.any? ? " supports #{wired_rows.map { |r| claim_alias(r) }.join(',')}" : "")
        notes.empty? ? answer : "#{answer} #{notes.join(' ')}"
      end

      def validate_fused!(fused)
        return nil if fused.nil?

        unless fused.is_a?(Array) && !fused.empty? && fused.all? do |e|
                 e.is_a?(Hash) && e["text"].is_a?(String) && !e["text"].strip.empty?
               end
          refuse("node_add", "fused-shape")
        end
        fused
      end

      # Byte-presence proof (L1 §3.8): the span is VERBATIM from the slice.
      # Explicit 0-based half-open offsets anchor directly (proven against
      # the snapshot); a text span is located by byte search.
      def locate_span!(span, source, snapshot, flat, nested)
        start = flat[:span_start] || nested[:span_start]
        finish = flat[:span_end] || nested[:span_end]
        if start && finish
          unless finish > start && finish <= snapshot.length
            refuse("node_add", "span-beyond-snapshot",
                   offsets: "offsets #{start}..#{finish}",
                   length: "length #{snapshot.length}",
                   src: source.fetch(:urn))
          end
          return [start, finish]
        end

        index = snapshot.index(span)
        return [index, index + span.length] if index

        refuse_unanchored(span, snapshot, source)
      end

      # The locating refusal (§6): nearest whitespace-normalized fragments +
      # the line junction — converts the unrecoverable re-flow class into a
      # one-shot fix.
      def refuse_unanchored(span, snapshot, source)
        norm = snapshot.gsub(/\s+/, " ")
        frag1 = span.gsub(/\s+/, " ")[0, 40].to_s.strip
        frag2 = span.gsub(/\s+/, " ")[-40, 40].to_s.strip
        line1 = norm.index(frag1) ? norm[0, norm.index(frag1)].count("\n") + 1 : 1
        junction = "#{line1}–#{line1 + 1}"
        refuse("node_add", "unanchored-span",
               fragments: "nearest fragments: \"#{frag1}\" | \"#{frag2}\"",
               junction: "lines #{junction}",
               src_seg: "blob of #{source.fetch(:urn)}")
      end

      def read_snapshot(source)
        location = Kquest::BlobUploader.location_for(:snapshot, user: user_id,
                                                            source_urn: source.fetch(:urn))
        Kquest::BlobUploader.uploaded_file(JSON.generate({"id" => location, "storage" => "store"})).read
      end

      # ── the dedup candidate check (I03 family d, BEFORE the write) ──────

      def check_dedup(text, _terminals)
        vector = probe_vector(text)
        Kquest::Queries::DedupCandidates.new(conn: conn)
          .candidates(user_id: user_id, text: text, probe_vector: vector)
      end

      def check_dedup_for_fused(fused)
        texts = Array(fused).map { |e| e.is_a?(Hash) ? e["text"] : e }
        exacts = []
        nears = []
        texts.each do |t|
          c = check_dedup(t, [])
          exacts.concat(c[:exact])
          nears.concat(c[:near])
        end
        {exact: exacts, near: nears}
      end

      # The probe vector: ONE EmbedBridge wire call for the claim text (the
      # near leg's cosine input). No model name anywhere — the registry path.
      def probe_vector(text)
        bridge = Kquest::Queries::EmbedBridge.new(conn: conn, config: config)
        bridge.vector_for(text)
      rescue Kquest::Pipeline::Error, Fast::Embeddings::Error
        nil # no registry path reachable: the near leg degrades to exact-only
      end

      def candiate_notes(candidates)
        rendered = rendered_candidates(candidates)
        rendered.empty? ? [] : [dedup_note(rendered)]
      end

      def rendered_candidates(candidates)
        candidates[:near].map { |r| "K#{r.quest_seq} (near_dup, cosine #{r.cosine})" }
      end

      # The quest-level idem-keyed claim embed job (the landed Enqueue mint —
      # noop when complete) so the near leg's vectors exist without new
      # schema; the ENTRY 4+ phase machinery may re-mint idempotently.
      def mint_claim_embed_job!
        model_id = Kquest::Queries.config_value(conn, "tools.claim_embedding_model")
        Kquest::Pipeline::Enqueue.embed(model_id: model_id, target_kind: "claim",
                                        quest_id: quest_id, user_id: user_id, phase_id: phase_id)
      end
    end
  end
end
