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
    #
    # The I19 grant-admin (the dashboard's workspace-admin WRITE half, Spec
    # Part 1): the writes are USER-scoped — no quest, no session — and every
    # landed audit ledger (tool_calls / quest_lifecycle_events / usage_events)
    # is quest-bound (NOT NULL FKs) and CANNOT carry them. The ruling (I19
    # Grounds §4.1/§5.4, the console_mute precedent class): the I02 ROWS are
    # the records — grants carry a REQUIRED note (who/why; the row's own
    # owner_user_id + granted_at carry who/when), workspace creation lands
    # created_by_user_id AND the creator's membership row in ONE transaction
    # (the frozen I02 fixture shape: the creator IS a member), membership
    # writes land joined_at. Renames, member removals, and revocations have
    # NO event carrier in the frozen model — the row's current state IS the
    # record (revocation IS row deletion: private = absence, the I02 law).
    # The two owner gates select by (id, owner) — nil means the action 404s
    # BEFORE any mutation (existence never leaked). Every refusal is a
    # teaching Kquest::Engine::Error the action renders 422 — the DB
    # CHECKs/FKs are the backstop, never the user-facing error. Zero-auto is
    # absolute: no spawn, no publish, no provider machinery anywhere here.
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

      # ── I19 grant-admin doors (the dashboard's workspace-admin WRITE half;
      # Spec Part 1) ──────────────────────────────────────────────────────

      # The workspace name slug law (ck_workspaces_name) — the teaching text
      # quotes it verbatim.
      WORKSPACE_NAME_LAW = '^[a-z0-9][a-z0-9-]{0,63}$'

      # The workspace row selected by (id, created_by_user_id) or nil — the
      # owner_quest! shape over I02's workspaces. Ownership IS admin: the
      # model has no other workspace role. Actions 404 on nil BEFORE any prop
      # assembly or mutation — existence never leaked (the I17 Finding-2
      # posture).
      def owned_workspace!(conn, user_id:, workspace_id:)
        conn[:workspaces].where(id: workspace_id, created_by_user_id: user_id).first
      end

      # The grant row selected by (id, owner_user_id) or nil — the same
      # posture over I02's resource_grants, ANY scope: the row is the
      # operator's own.
      def owned_grant!(conn, user_id:, grant_id:)
        conn[:resource_grants].where(id: grant_id, owner_user_id: user_id).first
      end

      # CREATE WORKSPACE: the workspaces row (created_by_user_id = the
      # operator) AND the creator's workspace_members row in ONE transaction
      # (the frozen I02 fixture shape — the creator IS a member; membership
      # is the read primitive, ownership the admin primitive). Teaching
      # FIRST (refusal paths precede any write): blank name, the slug law
      # (ck_workspaces_name), the GLOBAL uniqueness (uq_workspaces_name).
      def create_workspace!(conn, user:, name:)
        name = name.to_s.strip
        raise Kquest::Engine::Error, "name is required" if name.empty?
        unless name.match(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
          raise Kquest::Engine::Error,
                "name must match '#{WORKSPACE_NAME_LAW}' — a lowercase slug, 1-64 chars " \
                "(ck_workspaces_name)"
        end
        if conn[:workspaces].where(name: name).first
          raise Kquest::Engine::Error,
                "a workspace named '#{name}' already exists — uq_workspaces_name is global; " \
                "pick another slug"
        end
        created = nil
        conn.transaction do
          workspace_id = conn[:workspaces].insert(name: name,
                                                  created_by_user_id: user.fetch(:id))
          conn[:workspace_members].insert(workspace_id: workspace_id,
                                          user_id: user.fetch(:id))
          created = conn[:workspaces].where(id: workspace_id).first
        end
        created
      end

      # RENAME WORKSPACE: the same three teaching classes; the uniqueness
      # check EXCLUDES this workspace's own id (renaming to its own name is
      # a no-op success, not a refusal). The who is pinned by the owner
      # gate; the frozen model has no rename-event carrier (I19 Grounds
      # §4.1) — the row's current name IS the state.
      def rename_workspace!(conn, user:, workspace:, name:)
        name = name.to_s.strip
        raise Kquest::Engine::Error, "name is required" if name.empty?
        unless name.match(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
          raise Kquest::Engine::Error,
                "name must match '#{WORKSPACE_NAME_LAW}' — a lowercase slug, 1-64 chars " \
                "(ck_workspaces_name)"
        end
        if conn[:workspaces].where(name: name).exclude(id: workspace.fetch(:id)).first
          raise Kquest::Engine::Error,
                "a workspace named '#{name}' already exists — uq_workspaces_name is global; " \
                "pick another slug"
        end
        renamed = nil
        conn.transaction do
          conn[:workspaces].where(id: workspace.fetch(:id)).update(name: name)
          renamed = conn[:workspaces].where(id: workspace.fetch(:id)).first
        end
        renamed
      end

      # ADD MEMBER: the grantee user by users.handle (the unique slug).
      # Teaching: unknown handle; duplicate membership (X40's refusal —
      # pk_workspace_members — taught BEFORE the insert). joined_at defaults
      # to now — the when-carrier.
      def add_workspace_member!(conn, user:, workspace:, handle:)
        handle = handle.to_s.strip
        member = conn[:users].where(handle: handle).first
        unless member
          raise Kquest::Engine::Error,
                "no user with handle '#{handle}' — members are added by handle " \
                "(users.handle, the unique slug)"
        end
        if conn[:workspace_members].where(workspace_id: workspace.fetch(:id),
                                          user_id: member.fetch(:id)).first
          raise Kquest::Engine::Error,
                "'#{handle}' is already a member of #{workspace.fetch(:name)} — one membership " \
                "per (workspace, user) (pk_workspace_members)"
        end
        added = nil
        conn.transaction do
          conn[:workspace_members].insert(workspace_id: workspace.fetch(:id),
                                          user_id: member.fetch(:id))
          added = conn[:workspace_members].where(workspace_id: workspace.fetch(:id),
                                                 user_id: member.fetch(:id)).first
        end
        added
      end

      # REMOVE MEMBER: not-a-member is the teaching refusal (the
      # mute-remove shape — "nothing to remove"). Deleting the creator's own
      # membership is lawful (no creator-membership invariant in the frozen
      # schema; created_by admin rights are unaffected — membership is the
      # read primitive only).
      def remove_workspace_member!(conn, user:, workspace:, handle:)
        handle = handle.to_s.strip
        member = conn[:users].where(handle: handle).first
        row = member && conn[:workspace_members].where(workspace_id: workspace.fetch(:id),
                                                       user_id: member.fetch(:id)).first
        unless row
          raise Kquest::Engine::Error,
                "'#{handle}' is not a member of #{workspace.fetch(:name)} — nothing to remove"
        end
        conn.transaction do
          conn[:workspace_members].where(workspace_id: workspace.fetch(:id),
                                         user_id: member.fetch(:id)).delete
        end
        nil
      end

      # The (urn, owner) source lookup the grant doors share — the composite
      # FK fk_resource_grants_source (source_id, owner_user_id) pins
      # ownership; looking up by (urn, user_id) BEFORE any insert teaches
      # the X38 class instead of 500ing on the FK.
      def owned_source!(conn, user_id:, urn:)
        conn[:sources].where(urn: urn.to_s.strip, user_id: user_id).first
      end

      # GRANT TO WORKSPACE: the source MUST be the operator's own (the X38
      # class taught, never 500'd), the note is REQUIRED (the mute's
      # REQUIRED-reason law — the row records who/why), and a duplicate
      # (source → this workspace) is taught (NO schema unique exists on
      # (source, grantee) — duplicate grant rows are schema-legal; the door
      # keeps the ledger honest rows-for-grants-issued). The exactly-one
      # grantee shape is fixed by THIS insert (one grantee column set) —
      # X35/X36/X37 are structurally unreachable through the door.
      def create_workspace_grant!(conn, user:, workspace:, source_urn:, note:)
        note = note.to_s.strip
        source = owned_source!(conn, user_id: user.fetch(:id), urn: source_urn)
        unless source
          raise Kquest::Engine::Error,
                "no source with urn '#{source_urn.to_s.strip}' owned by you — grants are " \
                "owner-only (fk_resource_grants_source pins the source's owner)"
        end
        if note.empty?
          raise Kquest::Engine::Error,
                "a note is required — the grant records who/why, never a silent visibility change"
        end
        if conn[:resource_grants].where(source_id: source.fetch(:id),
                                        grantee_workspace_id: workspace.fetch(:id)).first
          raise Kquest::Engine::Error,
                "source '#{source_urn.to_s.strip}' is already granted to " \
                "#{workspace.fetch(:name)} — revoke that grant first if you mean to change it"
        end
        grant_id = nil
        conn.transaction do
          grant_id = conn[:resource_grants].insert(
            owner_user_id: user.fetch(:id), source_id: source.fetch(:id),
            grantee_workspace_id: workspace.fetch(:id), is_public: false, note: note
          )
        end
        conn[:resource_grants].where(id: grant_id).first
      end

      # GRANT PUBLIC: the same source/note teaching; the duplicate class is
      # the source's EXISTING public grant (the ladder's bool_or aggregates
      # duplicates away, so the door refuses a second one first).
      def create_public_grant!(conn, user:, source_urn:, note:)
        note = note.to_s.strip
        source = owned_source!(conn, user_id: user.fetch(:id), urn: source_urn)
        unless source
          raise Kquest::Engine::Error,
                "no source with urn '#{source_urn.to_s.strip}' owned by you — grants are " \
                "owner-only (fk_resource_grants_source pins the source's owner)"
        end
        if note.empty?
          raise Kquest::Engine::Error,
                "a note is required — the grant records who/why, never a silent visibility change"
        end
        if conn[:resource_grants].where(source_id: source.fetch(:id), is_public: true).first
          raise Kquest::Engine::Error,
                "source '#{source_urn.to_s.strip}' already has a public grant — revoke it " \
                "first if you mean to change it"
        end
        grant_id = nil
        conn.transaction do
          grant_id = conn[:resource_grants].insert(
            owner_user_id: user.fetch(:id), source_id: source.fetch(:id),
            grantee_user_id: nil, grantee_workspace_id: nil, is_public: true, note: note
          )
        end
        conn[:resource_grants].where(id: grant_id).first
      end

      # REVOKE: the grant row is the operator's own (the action gated via
      # owned_grant!; ANY scope — user, workspace, public). Deletion =
      # private-or-lower (the I02 absence-law): the ladder re-derives on the
      # next read. ONE transaction, no teaching class beyond the action's
      # 404 gate.
      def revoke_grant!(conn, user:, grant:)
        conn.transaction do
          conn[:resource_grants].where(id: grant.fetch(:id)).delete
        end
        nil
      end


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
