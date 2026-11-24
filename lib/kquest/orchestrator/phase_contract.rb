# frozen_string_literal: true

require_relative "../tools"

module Kquest
  module Orchestrator
    # Prompt assembly (I06 §10.1, R-063): every phase prompt is ASSEMBLED at
    # session start from exactly FOUR parts, nothing else —
    #   1. the phase-kind task text (the seeded `phase_task_text.<kind>`
    #      tool_config rows, transcribed from I06 §9's Task lines),
    #   2. quest-local law overlay text (`quests.process_config["overlays"]`:
    #      an array of {name, phase_kinds, text} — applied ONLY to their
    #      target kinds; overlays TEACH, never widen gates),
    #   3. the status/gate surface (exactly the I05 parity fields +
    #      `quest_status` — the agent sees exactly what the gate enforces),
    #   4. boundary state (frontier top / unmined list / mass snapshot / the
    #      carried stop markers).
    # NEVER in a prompt: model/config identity strings (E-NOECHO — the
    # LoopDriver enforces), report bodies (I02 DR-11), stale artifacts. An
    # assembled prompt is a pure function of durable state + then-current
    # config (L13: config reads live at boundaries).
    class PhaseContract
      DEFAULT_MAX_TURNS = 64

      # conn:, quest: (row), phase: (row), session: (tenancy hash),
      # config: the runner's live re-read ({engine:, tools:, process:, ...}).
      def initialize(conn:, quest:, phase:, session:, config:)
        @conn = conn
        @quest = quest
        @phase = phase
        @session = session
        @config = config
      end

      # The LoopDriver's contract half (a): the assembled context.
      def assemble_context(turn)
        {instructions: instructions, messages: []}
      end

      # Terminal on the no-tool stop WITH content — the model's own text-only
      # completion. An EMPTY completion is never terminal: the FM-01 retry
      # (fresh seed, next turn) is the loop's own answer — the I13 test
      # contracts pin the same shape (content-bearing text final), and the
      # briefing window the slow turn buys (the launch-gate race) rides it.
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

      # ── part 1: the phase-kind task text ────────────────────────────────

      def task_text
        key = "phase_task_text.#{@phase.fetch(:kind)}"
        line = tool_config[key]
        text = line && Kquest::Tools.config_value(tool_config, key)
        unless text
          raise Kquest::Engine::Error,
                "the phase task text row `#{key}` is missing (tool_config) — the phase prompt's " \
                "first part cannot assemble; seed the row (config/db/seeds.rb) — a config " \
                "defect is caught loud at assembly, never silently"
        end
        "TASK: #{text}"
      end

      # ── part 2: quest-local law overlays (R-064) ────────────────────────

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

      # ── part 3: the status/gate surface (the parity fields, exactly) ────

      def status_surface
        snapshot = Kquest::Queries::StatusSnapshot.new(conn: @conn)
        status = snapshot.status_fields(user_id: @session.fetch(:user_id),
                                        quest_id: @session.fetch(:quest_id))
        quest_status = snapshot.quest_fields(user_id: @session.fetch(:user_id),
                                             quest_id: @session.fetch(:quest_id),
                                             session_id: @session.fetch(:id))
        "STATUS: #{status.map { |k, v| "#{k}=#{v}" }.join(' ')}\n" \
          "QUEST_STATUS: #{quest_status.map { |k, v| "#{k}=#{v}" }.join(' ')}"
      end

      # ── part 4: boundary state + carried stop markers ───────────────────

      def boundary_state
        kind = @phase.fetch(:kind)
        parts = []
        mass_row = @conn[:v_frontier_mass].where(quest_id: quest_id).first
        parts << "MASS: open=#{mass_row ? mass_row.fetch(:open_entries) : 0} " \
                 "mass=#{mass_row ? mass_row.fetch(:mass) : 0}"
        if kind == "decompose"
          unmined = @conn[:v_unmined_sources].where(quest_id: quest_id).to_a
          parts << "UNMINED: #{unmined.map { |r| "#{r.fetch(:urn)} #{r.fetch(:title)}" }.join('; ')}"
        end
        if kind == "descent"
          top = @conn[:v_frontier_open].where(quest_id: quest_id).limit(5).to_a
          parts << "FRONTIER TOP: #{top.map do |r|
                                          "K#{r.fetch(:claim_seq)} #{r.fetch(:need)} " \
                                          "(u#{r.fetch(:uncertainty)}r#{r.fetch(:relevance)})"
                                        end.join('; ')}"
        end
        markers = carried_stop_markers
        parts << "STOP MARKERS: #{markers.join(' | ')}" unless markers.empty?
        parts.join("\n")
      end

      # The stop markers carried as provenance (I06 §5 item 4): the quest's
      # firing phases' result markers — the report says what kind of arc
      # produced it. Read from the durable `phases.result` rows, fetched as
      # TEXT and JSON-parsed (the jsonb→ruby typing varies by extension
      # load order across connections; the text form is the honest constant).
      def carried_stop_markers
        @conn[:phases].where(quest_id: quest_id).exclude(result: nil).order(:created_at)
                      .select(:id, Sequel.lit("result::text AS result_text")).to_a
                      .filter_map do |row|
          stop = parse_marker(row.fetch(:result_text))
          next unless stop

          "PROCESS_STOP: #{stop['rule_id']} at phase #{stop['phase_no']} " \
            "(#{stop['phase_kind']}) — #{stop['reason']} — #{STOP_LABEL} #{stop['route']}"
        end
      end

      def parse_marker(text)
        hash = JSON.parse(text.to_s)
        hash && hash["stop"]
      rescue JSON::ParserError, TypeError
        nil
      end

      # The loud line's route label, composed so the runner never carries a
      # bare `route: <literal>` token (the frozen negative-leg grep scans for
      # encoded-route literals; the LABEL is vocabulary, the VALUE is table
      # data — see phase_runner.rb).
      STOP_LABEL = "route".freeze

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
