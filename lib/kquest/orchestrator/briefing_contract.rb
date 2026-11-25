# frozen_string_literal: true

require "json"
require_relative "../tools"
require_relative "../queries/status_snapshot"

module Kquest
  module Orchestrator
    # The briefing chat's prompt assembly (I18 the §8 amendment; I06 §10.1's
    # four-part law, the PhaseContract's own shape, bound to the OPERATOR
    # session's binding decompose round-1 phase):
    #   1. the task text — the seeded `phase_task_text.briefing` tool_config
    #      row (provenance: I06 §8 + the §8 amendment); a missing row is the
    #      LOUD assembly refusal (the PhaseContract's own law);
    #   2. quest-local law overlays targeting the binding phase kind
    #      (decompose);
    #   3. the status/gate parity surface — the eight parity fields PLUS
    #      `agenda_staged` (the gate the conversation drives) and the three
    #      budget lines (the quest_status parity fields, the PhaseContract's
    #      own rendering), with the web-call count on the EXTENDED predicate
    #      (a staging fetch IS a web call — Grounds §4.5/§5.7);
    #   4. boundary state — the staged agenda list (urn + title, capped),
    #      the current topic questions (the phases.result carrier), the
    #      topic.
    # Messages (the LoopDriver's caller-built `chat:` half) are REBUILT from
    # durable state (L7): the session ledger blob's `operator` lines (user
    # turns) + `final` lines (assistant turns) + the `tool_result` lines
    # paired to their `tool_call` blocks (the harness's call-order audit) —
    # never in-memory-only state. E-NOECHO applies (the driver enforces).
    class BriefingContract
      DEFAULT_MAX_TURNS = 64
      TASK_KEY = "phase_task_text.briefing".freeze
      AGENDA_CAP_KEY = "ui.listing_cap.briefing".freeze
      AGENDA_CAP_DEFAULT = 30

      # conn:, quest: (row), phase: (the binding decompose round-1 row),
      # session: (the OPERATOR session tenancy hash), config: the live
      # re-read ({engine:, tools:, process:, model_config:, stop_rules:}),
      # ledger: the exchange's OWN TranscriptLedger instance (the blob reader
      # — in test the MemorySink is per-instance, so the append side and the
      # read side must be the same object; Grounds §4.3).
      def initialize(conn:, quest:, phase:, session:, config:, ledger:)
        @conn = conn
        @quest = quest
        @phase = phase
        @session = session
        @config = config
        @ledger = ledger
      end

      # The LoopDriver's contract half (a): the assembled context. The
      # messages half is the durable conversation (the driver applies it once
      # through the caller-built chat — phase_runner.rb#build_chat's recipe).
      def assemble_context(turn)
        {instructions: instructions, messages: conversation}
      end

      # Terminal on the no-tool stop WITH content — the PhaseContract's exact
      # shape (content-bearing text-only completion, turn >= 1; an EMPTY
      # completion is never terminal — FM-01 owns the retry).
      def terminal?(turn:, chat:)
        return false unless chat.complete? && turn >= 1

        message = chat.messages.last
        return false unless message

        Array(message.content).any? do |block|
          block.is_a?(Hash) && block[:type] == :text && !block[:text].strip.empty?
        end
      end

      def max_turns
        process_value("phase.max_turns") || DEFAULT_MAX_TURNS
      end

      private

      def instructions
        [task_text, overlay_text, status_surface, boundary_state].compact.join("\n")
      end

      # ── part 1: the seeded briefing task text ───────────────────────────

      def task_text
        line = tool_config[TASK_KEY]
        text = line && Kquest::Tools.config_value(tool_config, TASK_KEY)
        unless text
          raise Kquest::Engine::Error,
                "the phase task text row `#{TASK_KEY}` is missing (tool_config) — the briefing " \
                "prompt's first part cannot assemble; seed the row (config/db/seeds.rb) — a " \
                "config defect is caught loud at assembly, never silently"
        end
        "TASK: #{text}"
      end

      # ── part 2: quest-local law overlays (R-064) — decompose-targeting ──

      def overlay_text
        overlays = Array(@config.fetch(:process).fetch("overlays", nil))
        mine = overlays.select do |o|
          next false unless o.is_a?(Hash)

          kinds = Array(o["phase_kinds"])
          kinds.empty? || kinds.include?(@phase.fetch(:kind))
        end
        return nil if mine.empty?

        mine.map { |o| "OVERLAY #{o['name']}: #{o['text']}" }.join("\n")
      end

      # ── part 3: the status/gate parity surface ──────────────────────────

      def status_surface
        snapshot = Kquest::Queries::StatusSnapshot.new(conn: @conn)
        status = snapshot.status_fields(user_id: user_id, quest_id: quest_id)
        fields = snapshot.quest_fields(user_id: user_id, quest_id: quest_id,
                                       session_id: @session.fetch(:id))
        fields[:web_used] = extended_web_calls_used
        "STATUS: #{status.map { |k, v| "#{k}=#{v}" }.join(' ')} agenda_staged=#{agenda_staged?}\n" \
          "QUEST_STATUS: #{fields.map { |k, v| "#{k}=#{v}" }.join(' ')}"
      end

      # ── part 4: boundary state — the conversation's durable context ─────

      def boundary_state
        parts = []
        agenda = agenda_rows
        listing = agenda.map { |r| "#{r.fetch(:urn)} \"#{r.fetch(:title)}\"" }.join("; ")
        parts << (listing.empty? ? "AGENDA STAGED: none yet" : "AGENDA STAGED: #{listing}")
        questions = topic_questions
        parts << (questions.empty? ? "TOPIC QUESTIONS: none recorded yet"
                                    : "TOPIC QUESTIONS: #{questions.join(' | ')}")
        parts << "TOPIC: #{@quest.fetch(:topic)}"
        parts.join("\n")
      end

      # The staged agenda list (readable, NEVER anchorable/citable — I06 §8),
      # capped at the ui.listing_cap.briefing row (L15).
      def agenda_rows
        @conn[:quest_sources]
          .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => quest_id,
                 Sequel[:sources][:user_id] => user_id,
                 Sequel[:sources][:role] => "agenda")
          .order(Sequel.desc(Sequel[:quest_sources][:added_at]), Sequel.desc(Sequel[:sources][:id]))
          .select(Sequel[:sources][:urn], Sequel[:sources][:title])
          .limit(agenda_cap).to_a
      end

      def agenda_cap
        return AGENDA_CAP_DEFAULT unless tool_config.key?(AGENDA_CAP_KEY)

        Kquest::Tools.config_value(tool_config, AGENDA_CAP_KEY) || AGENDA_CAP_DEFAULT
      end

      # The gate the conversation drives (the `agenda_staged` predicate's
      # READ — ≥1 role-agenda source joined on the quest; the predicate
      # itself is unchanged machinery).
      def agenda_staged?
        agenda_count.positive?
      end

      def agenda_count
        @conn[:quest_sources]
          .join(:sources, Sequel[:sources][:id] => Sequel[:quest_sources][:source_id])
          .where(Sequel[:quest_sources][:quest_id] => quest_id,
                 Sequel[:sources][:user_id] => user_id,
                 Sequel[:sources][:role] => "agenda").count
      end

      # The current topic questions (the I03 DR-14 carrier): read from the
      # binding phase's durable `phases.result` jsonb — read as TEXT and
      # JSON-parsed (the jsonb→ruby typing varies by extension load order —
      # the text form is the honest constant).
      def topic_questions
        text = @conn[:phases].where(id: @phase.fetch(:id)).get(Sequel.lit("result::text"))
        return [] unless text

        Array(JSON.parse(text).fetch("topic_questions", []))
      rescue JSON::ParserError
        []
      end

      # ── the durable conversation (L7) ───────────────────────────────────

      # The session ledger blob's lines → wire messages. `operator` → user;
      # `final` → assistant (its tool_call ids carry forward); each turn's
      # `tool_result` lines pair with the assistant's tool_call blocks BY
      # NAME in call order (the blob's tool_result lines carry tool+args but
      # no id — the harness's call-order audit is the pairing law).
      # `text_delta`/`thinking_delta` duplicate the final they belong to;
      # `salvage` is audit-only (never live history) — both skipped.
      def conversation
        messages = []
        pending_results = []
        blob_lines.each do |line|
          case line["type"]
          when "operator"
            pending_results.clear
            messages << Fast::Completions::Message.user(line["body"].to_s)
          when "final"
            hash = line["message"]
            next unless hash

            message = wire_message(hash)
            messages << message
            blocks = Array(message.content).select do |b|
              b.is_a?(Hash) && b[:type] == :tool_call
            end
            blocks.each do |block|
              idx = pending_results.index { |r| r["tool"] == block[:name] }
              next unless idx

              result = pending_results.delete_at(idx)
              messages << Fast::Completions::Message.tool_result(
                tool_call_id: block[:id], content: result["content"].to_s,
                tool_name: block[:name], is_error: result["is_error"] == true
              )
            end
            pending_results.clear
          when "tool_result"
            pending_results << line
          end
        end
        messages
      end

      def blob_lines
        bytes = @ledger.sink.read(@ledger.location)
        return [] unless bytes

        bytes.split("\n").filter_map { |l| JSON.parse(l) rescue nil }
      end

      # The blob is JSON: keys symbolized AND the content blocks' enum VALUES
      # restored to the gem's symbols (the wire mapping matches block[:type]
      # against :text/:tool_call/:thinking — the in-memory shape, not the
      # serialized one).
      BLOCK_TYPES = %w[text tool_call thinking].map { |t| [t, t.to_sym] }.to_h.freeze

      # The streamed final carries consumer-owned metadata stamps (provider,
      # model, api, usage, response ids) — the gem stamps them on every
      # streamed message. The rebuilt conversation carries role+content ONLY:
      # identity lives in sessions.model/usage_events.model (E-NOECHO — the
      # driver enforces on EVERY turn's assembled context, so a rebuilt
      # history carrying the provider/model stamps would refuse the exchange).
      WIRE_METADATA_KEYS = %i[provider model api usage response_id response_model
                              stop_reason].freeze

      def wire_message(hash)
        symbolized = deep_symbolize(hash)
        WIRE_METADATA_KEYS.each { |k| symbolized.delete(k) }
        Fast::Completions::Message.from_h(symbolized)
      end

      def deep_symbolize(node)
        case node
        when Hash
          node.each_with_object({}) do |(k, v), h|
            h[k.to_sym] = k == "type" && BLOCK_TYPES.key?(v) ? BLOCK_TYPES.fetch(v) : deep_symbolize(v)
          end
        when Array then node.map { |v| deep_symbolize(v) }
        else node
        end
      end

      # ── shared lookups ──────────────────────────────────────────────────

      def extended_web_calls_used
        @conn[:tool_calls].where(quest_id: quest_id, ok: true)
                          .where(Sequel[:tool] => %w[web_search web_fetch agenda_stage]).count
      end

      def user_id = @session.fetch(:user_id)

      def quest_id = @session.fetch(:quest_id)

      def process_value(key)
        raw = @config.fetch(:process)[key]
        raw.is_a?(Numeric) ? raw : nil
      end

      def tool_config
        @tool_config ||= Kquest::Tools.config(@conn)
      end
    end
  end
end
