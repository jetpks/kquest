# frozen_string_literal: true

module Kquest
  module Pipeline
    # The embed body — the iteration's core. Everything wire- and cap-shaped
    # comes from the registry row (J-RET: active rows only); admission
    # control REFUSES over-length texts loudly BEFORE any wire call (never
    # truncates); batches slice by `batch_max_texts`; the reply zips by the
    # entry's `index` (the gem contract — wire order is never re-sorted);
    # each batch's vector rows + the `done_items` advance commit in ONE
    # transaction (L7: a kill between batches loses nothing, re-embeds
    # nothing); completion writes the J-SPEND usage row in the SAME
    # transaction as the terminal state (no orphan spend, ever) or fails
    # loudly when the D10 chain has no session to hang it on.
    class EmbedBody
      def initialize(conn: Kquest::App["db.gateway"].connection)
        @conn = conn
      end

      attr_reader :conn

      def run(row)
        model = registry_model(row)
        targets = enumerate_targets(row)

        if row[:done_items] > targets.size
          raise Error, "embed job #{row[:id]}: durable cursor #{row[:done_items]} is past the " \
                       "target set (#{targets.size}) — the target set SHRANK; refusing to write"
        end

        # total_items rides the pending→running transition (the progress
        # CHECK bites against a stale 0 total otherwise).
        State.mark_running!(conn, row, targets.size)

        pending = targets.drop(row[:done_items])
        assert_admission!(row, model, pending)

        client = Wire.client_for(model)
        api_key = KeyRef.resolve(model[:api_key_ref])
        input_tokens = 0
        pending.each_slice(model[:batch_max_texts]) do |batch|
          result = client.embed(model: model[:wire_name], input: batch.map { |t| t[:text] }, api_key: api_key)
          input_tokens += result.usage.prompt_tokens
          write_vectors!(row, model, batch, result)
        end

        complete_with_spend!(row, model, targets.size, input_tokens)
        nil
      end

      private

      # J-RET: the pipeline admits jobs against active registry rows only —
      # history survives a retire, new work does not.
      def registry_model(row)
        model = conn[:embedding_models].where(id: row[:model_id]).first
        raise Error, "embed job #{row[:id]}: registry model #{row[:model_id]} not found" unless model
        unless model[:status] == "active"
          raise Error, "embed job #{row[:id]}: registry model #{model[:slug]} is " \
                       "#{model[:status].inspect} — new work is refused against a retired row"
        end

        model
      end

      # The deterministic target orders (Grounds decision 7). Every target:
      # {id:, kind:, text:} — the id column for the vector table, the text
      # that crosses the wire verbatim.
      def enumerate_targets(row)
        case row[:target_kind]
        when "chunk"          then chunk_targets(row)
        when "claim"          then claim_targets(row)
        when "frontier_need"  then need_targets(row)
        else raise Error, "embed job #{row[:id]}: unknown target_kind #{row[:target_kind].inspect}"
        end
      end

      def chunk_targets(row)
        # The chunk leg joins quest_sources.source_id = chunks.source_id (NOT
        # chunks.id); hash-key joins do not qualify — explicit qualifications.
        # QUEST-NARROWED (judgment F-2, driver ruling 2026-11-24): the
        # membership join admits only the job's quest — a source staged to
        # two quests enumerates once per quest's job (no duplicate embed
        # work), and a source staged only to the user's OTHER quest never
        # leaks in (DR-06 ruling A: per-quest spend attribution).
        ds = conn[:chunks]
          .join(:quest_sources,
                Sequel[:quest_sources][:source_id] => Sequel[:chunks][:source_id],
                Sequel[:quest_sources][:user_id] => Sequel[:chunks][:user_id])
          .where(Sequel[:chunks][:user_id] => row[:user_id])
        ds = ds.where(Sequel[:quest_sources][:quest_id] => row[:quest_id])
        ds = ds.where(Sequel[:chunks][:strategy_id] => row[:strategy_id]) if row[:strategy_id]
        ds.order(Sequel[:chunks][:source_id], Sequel[:chunks][:ordinal])
          .select(Sequel[:chunks][:id], Sequel[:chunks][:text])
          .map { |r| {id: r[:id], kind: "chunk", text: r[:text]} }
      end

      def claim_targets(row)
        conn[:claims]
          .where(user_id: row[:user_id], quest_id: row[:quest_id])
          .order(:quest_seq)
          .select(:id, :canonical_text)
          .map { |r| {id: r[:id], kind: "claim", text: r[:canonical_text]} }
      end

      def need_targets(row)
        # Open AND closed needs keep their vectors (the order is the need's
        # ledger order, not a work-queue's liveness filter).
        conn[:frontier_entries]
          .where(user_id: row[:user_id], quest_id: row[:quest_id])
          .order(:opened_at, :id)
          .select(:id, :need)
          .map { |r| {id: r[:id], kind: "frontier_need", text: r[:need]} }
      end

      # Grounds decision 1: refusal, never a split (the per-target unique law
      # + embedded_text's rebuild-diff duty make the vector row 1:1 with its
      # target), and the refusal fires BEFORE any wire call.
      def assert_admission!(row, model, pending)
        over = pending.find { |t| t[:text].length > model[:input_max_chars] }
        return unless over

        raise Error, "embed job #{row[:id]}: refused #{over[:kind]} #{over[:id]} — " \
                     "text length #{over[:text].length} exceeds the registry cap input_max_chars " \
                     "#{model[:input_max_chars]} (never truncated; no wire call was made)"
      end

      # ONE transaction per batch: the per-target REPLACE (delete by the
      # target's id column for THIS model, then insert) and the cursor
      # advance commit together.
      def write_vectors!(row, model, batch, result)
        table = conn[model[:table_name].to_sym]
        by_index = {}
        result.data.each do |datum|
          index = datum.index
          unless index.is_a?(Integer) && index >= 0 && index < batch.size && !by_index.key?(index)
            raise Error, "embed job #{row[:id]}: wire reply index #{index.inspect} is out of range " \
                         "or duplicated for a #{batch.size}-text batch — refusing to mistranslate"
          end

          by_index[index] = datum
        end
        if by_index.size != batch.size
          raise Error, "embed job #{row[:id]}: wire reply covered #{by_index.size} of #{batch.size} " \
                       "batch texts by index — refusing to mistranslate"
        end

        conn.transaction do
          by_index.each do |index, datum|
            target = batch[index]
            replace_vector!(table, row, model, target, datum.embedding)
          end
          # SQL-side cumulative increment (judgment F-1): the cursor must
          # ACCUMULATE across batches — `row[:done_items]` is the once-loaded
          # row hash and never changes, so Ruby-side arithmetic re-writes
          # `orig + batch.size` on every batch and the durable ledger lies
          # between batches 2..n. Order-independent in SQL (I03 §6: the
          # cursor is exactly "targets embedded").
          conn[:embed_jobs].where(id: row[:id]).update(done_items: Sequel[:done_items] + batch.size)
        end
        nil
      end

      def replace_vector!(table, row, model, target, floats)
        kind = target[:kind]
        id_col = {chunk: :chunk_id, claim: :claim_id, frontier_need: :need_id}.fetch(kind.to_sym)
        table.where(model_id: model[:id], id_col => target[:id]).delete
        table.insert(
          model_id: model[:id],
          model_status: "active",
          user_id: row[:user_id],
          target_kind: kind,
          id_col => target[:id],
          embedding: "[" + floats.join(",") + "]",
          embedded_text: target[:text],
          job_id: row[:id]
        )
        nil
      end

      # The D10 chain must be total: the phase's LATEST session carries the
      # spend, or the job fails loudly — no orphan spend, ever. A
      # zero-target job still completes with a ZERO-token spend row (the
      # call is still an event — FM-25's posture).
      def complete_with_spend!(row, model, total_items, input_tokens)
        session = State.latest_session_of_phase(conn, row)
        unless session
          raise Error, "embed job #{row[:id]}: no session for phase #{row[:phase_id].inspect} — the " \
                       "user→quest→phase→session ledger chain must be total; no spend row without it"
        end

        State.mark_complete_with_spend!(conn, row, total_items,
          user_id: row[:user_id],
          quest_id: row[:quest_id],
          phase_id: row[:phase_id],
          session_id: session[:id],
          kind: "embedding",
          model: model[:wire_name],
          input_tokens: input_tokens,
          output_tokens: 0
        )
        nil
      end
    end
  end
end
