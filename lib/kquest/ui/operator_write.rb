# frozen_string_literal: true

require "json"

module Kquest
  module Ui
    # The ONE operator-write door (I17 Part 0.1 / L13: same tools, same
    # constraints, same audit; I08 §5.2: "the steering session's own
    # tool_calls-shaped audit when it mutates graph state"). Every I17 write
    # action composes THIS module — no action hand-rolls a session, an audit,
    # or a guard. The session gate is the LANDED SessionSupervisor#launch
    # (FM-16: the FOR-UPDATE quests lock FIRST, the liveness check, the
    # refusal naming the holder session + driver); the audit is the LANDED
    # TranscriptLedger#record_tool_call! (the ONE audit writer, I01 §3.15 —
    # same transaction as the write); the write-guard recheck is the
    # supervisor's own write_guard_for(session). The only sessions write in
    # the UI is the ended_at stamp (end_session!, through the supervisor's
    # bank_session!), and the only phases write is the briefing round-1 mint
    # (open_session!, I01 DR-13). The I18 chat (the §8 amendment): the topic
    # questions are the AGENT's write (the topic_questions tool, worker side)
    # — this module adds the operator-turn ENQUEUE door (enqueue_turn!, the
    # ONLY [:briefing_turns] writer in the web tree) and the dead-letter mark
    # on sign-off (end_session!).
    module OperatorWrite
      # The supervisor is constructed per call over the shared conn (the
      # liveness registry is the supervisor's own class-level default).
      module_function

      def supervisor(conn)
        Kquest::Engine::SessionSupervisor.new(conn: conn)
      end

      # The shared OWNER gate (Grounds §5.1): the quest row selected by
      # (id, user_id) or nil. Actions 404 on nil BEFORE any prop assembly or
      # mutation — existence is never leaked (the I16 read surfaces keep
      # visible_quest?; writes are owner-only, day one).
      def owner_quest!(conn, user_id:, quest_id:)
        conn[:quests].where(id: quest_id, user_id: user_id).first
      end

      # The quest's LIVE operator interactive session, find-or-launch.
      # REUSE the open `sessions` row (ended_at IS NULL, driver 'operator')
      # when one exists — claimed into liveness so the write-guard answers
      # live for it; a DIFFERENT live holder (e.g. the orchestrator worker)
      # raises the supervisor's FROZEN write-guard refusal naming the holder
      # session + driver (FM-16) — actions render it 422 verbatim. Otherwise
      # MINT the binding phase row when the quest has none (`phases` insert:
      # kind decompose, round 1, attempt 1, state pending — I01 DR-13's
      # "decompose round 1, attempt 1" for pre-phase work) and launch through
      # the gate (mode interactive, driver operator). When the quest already
      # HAS phases, the session binds to the quest's LATEST phase row: the
      # report tools' schema law (fk_report_versions_phase pins
      # synthesis_phase_id to a kind-synthesis phase) makes the binding phase
      # the only shape the L13 report writes can land through. Returns the
      # session row (a Hash).
      def open_session!(conn, user:, quest:)
        sup = supervisor(conn)
        if (open = current_session(conn, quest_id: quest.fetch(:id)))
          sup.live_sessions << open.fetch(:id) # claim into liveness (reuse)
          return open
        end

        # No operator session: a live holder of ANY other session is the
        # one-writer law — refuse with the supervisor's own words (FM-16).
        if (holder = sup.live_holder(quest.fetch(:id)))
          raise Kquest::Engine::Error.new(
            sup.write_guard_refusal(quest_id: quest.fetch(:id), session_id: holder[:id],
                                    driver: holder[:driver]),
            error_class: "WriteGuard"
          )
        end

        phase = conn[:phases].where(quest_id: quest.fetch(:id))
                             .order(Sequel.desc(:created_at), Sequel.desc(:id)).first ||
                mint_round_one_phase!(conn, user_id: user.fetch(:id), quest_id: quest.fetch(:id))
        model = model_for(conn, quest, "decompose")
        session_id = sup.launch(
          user_id: user.fetch(:id), quest_id: quest.fetch(:id), phase_id: phase.fetch(:id),
          mode: "interactive", driver: "operator", model: model
        )
        conn[:sessions].where(id: session_id).first
      end

      # The open operator session row or nil (read-only — the briefing/write
      # actions 422 with a teaching refusal when a required session is absent).
      def current_session(conn, quest_id:)
        conn[:sessions].where(quest_id: quest_id, driver: "operator", ended_at: nil)
                       .order(Sequel.desc(:started_at), Sequel.desc(:id)).first
      end

      # ONE Sequel transaction: the write-guard recheck (the FM-16 defense in
      # depth), then the LANDED tool. A tool refusal-that-teach
      # (Kquest::Engine::Error) is audited ok=false (the tool's census rule-id
      # as error_class) and returned as {ok: false, outcome:, error_class:} —
      # the action maps it to 422 carrying the refusal text. The pre-tool
      # write-guard refusal is returned WITHOUT an audit row: no tool call was
      # made, and the refusal names the OTHER holder session (the holder's own
      # ledger is the record — I08 §5.2: not a second ledger).
      def write!(conn, session:, tool_name:, args:)
        sup = supervisor(conn)
        result = nil
        begin
          conn.transaction do
            sup.write_guard_for(session).call
            ledger = Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
            tool = Kquest::Tools.build(tool_name, conn: conn, session: session,
                                                   ledger: ledger, config: Kquest::Tools.config(conn))
            result = tool.execute(**args)
            ledger.record_tool_call!(tool: tool_name, args: args,
                                     result: {content: result, is_error: false}, ok: true)
          end
        rescue Kquest::Engine::Error => e
          # The pre-tool write-guard refusal (FM-16): returned WITHOUT an
          # audit row — no tool call was made, and the refusal names the
          # OTHER holder session (the holder's own ledger is the record —
          # I08 §5.2: not a second ledger).
          return {ok: false, outcome: e.message, error_class: e.error_class} if e.error_class == "WriteGuard"

          # A refusal-that-teach from the tool: the tool's own words, audited
          # ok=false in ONE transaction (refusal paths precede any write, so
          # the unwound transaction's rollback is empty and this audit
          # commit is the whole effect).
          conn.transaction do
            Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
                                             .record_tool_call!(tool: tool_name, args: args,
                                                                result: {content: e.message, is_error: true},
                                                                ok: false, error_class: e.error_class)
          end
          {ok: false, outcome: e.message, error_class: e.error_class}
        else
          {ok: true, outcome: result, error_class: nil}
        end
      end

      # The `tool_calls`-shaped audit for writes with NO landed tool (I08
      # §5.2's own words) — the same ledger method, one call, in the CALLER's
      # transaction. NEVER a second audit writer.
      def record!(conn, session:, tool:, args:, result:, ok:, error_class: nil)
        Kquest::Engine::TranscriptLedger.new(conn: conn, session: session)
                                         .record_tool_call!(tool: tool, args: args, result: result,
                                                            ok: ok, error_class: error_class)
        nil
      end

      # ENQUEUE one operator chat turn (I18 the §8 amendment; Spec Part 2.1):
      # ONE [:briefing_turns] insert (state `enqueued`) with the per-session
      # `seq` (max+1 — the record_tool_call! pattern). The ONLY briefing_turns
      # writer in the web tree; NO provider machinery, no spawn, no publish
      # (BRIEF §3 zero-auto — the row IS the operator turn's durable record;
      # the WORKER consumes and executes). A blank body refuses teaching
      # BEFORE the insert (the CHECK law taught as a 422-class refusal the
      # action renders; ck_briefing_turns_body_nonempty is the backstop).
      def enqueue_turn!(conn, session:, body:)
        text = body.to_s.strip
        if text.empty?
          raise Kquest::Engine::Error,
                "the message is empty — write the operator turn you want the agent to " \
                "address; an empty message teaches, it never enqueues"
        end
        seq = conn[:briefing_turns].where(session_id: session.fetch(:id)).max(:seq).to_i + 1
        conn[:briefing_turns].insert(
          user_id: session.fetch(:user_id), quest_id: session.fetch(:quest_id),
          session_id: session.fetch(:id), seq: seq, body: text
        )
        seq
      end

      # Stamps `ended_at` on the open operator session — the DR-04 sign-off /
      # the console attach end. Raises the teaching refusal when none is open
      # (the action renders 422). The stamp rides the supervisor's own
      # bank_session! (ended_at + the liveness release — one landed writer).
      # The DEAD-LETTER MARK (I18 Spec Part 2.1 + the banked-session edge,
      # PH0-CU-1): the quest's operator sessions' still-`enqueued` turns flip
      # `skipped` — ONE UPDATE, same door. Keyed to the QUEST's operator
      # sessions (not just the one being ended) because a governor-banked
      # session (the engine's own bank_session! path) closes the row WITHOUT
      # this door, and its leftover enqueued turns can never be consumed
      # afterwards; the next sign-off is the only lawful door that reaches
      # them. An ended session never consumes; the page shows the turns
      # unsent, never silently dropped.
      def end_session!(conn, quest_id:)
        session = current_session(conn, quest_id: quest_id)
        unless session
          raise Kquest::Engine::Error,
                "no open operator session on quest #{quest_id} — the sign-off ends a LIVE " \
                "briefing session (open one first)"
        end
        supervisor(conn).bank_session!(session_id: session.fetch(:id))
        conn[:briefing_turns]
          .where(session_id: conn[:sessions].where(quest_id: quest_id,
                                                   driver: "operator").select(:id),
                 state: "enqueued")
          .update(state: "skipped")
        session
      end

      # ── internals ───────────────────────────────────────────────────────

      # The binding decompose round-1 phase (I01 DR-13): kind decompose,
      # round 1, attempt 1, state pending — minted ONLY when the quest has no
      # phase rows at all. The ONE phases write this module owns.
      def mint_round_one_phase!(conn, user_id:, quest_id:)
        phase_id = conn[:phases].insert(user_id: user_id, quest_id: quest_id,
                                        kind: "decompose", round_no: 1, attempt_no: 1,
                                        state: "pending")
        conn[:phases].where(id: phase_id).first
      end

      # The routing map names the model per phase kind (the runner's own
      # read); the operator session's fallback model is the literal
      # "operator" (the session row's model column is CHECK-nonempty only).
      def model_for(conn, quest, kind)
        config = quest.fetch(:model_config)
        config = JSON.parse(config) if config.is_a?(String)
        name = config.is_a?(Hash) ? config[kind] : nil
        name.to_s.strip.empty? ? "operator" : name
      end
    end
  end
end
