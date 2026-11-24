# frozen_string_literal: true

require "json"

module Kquest
  module Engine
    # The failure-table executor (I04 §2.5, R-039/R-045): signature → class →
    # required behavior → bound. Jittered exponential backoff ABOVE the gem's
    # L0 immediate creation retry — `sleep = rand · min(cap, base · 2^attempt)`
    # — with per-class caps from `engine_config` (retry caps never consult
    # `mode` — DR-09's advisory law is budget-guard-only). Each attempt
    # carries a FRESH seed (the governor refuses an identical (body, seed)
    # re-attempt — FM-03's write-time complement), the L2 banking (session
    # banked at the turn boundary, committed mutations survive,
    # `phases.attempt_no` counts), and the L3 escalation-to-pause
    # (`quests.state` + a `quest_lifecycle_events` row — I02's ledgered
    # transition; the transition write itself lives on SessionSupervisor,
    # E-PAUSE's primary enforcement point).
    #
    # The SHARED classes cover the embed call site (FM-23 — I03 DR-07
    # deferred those classes here): `site: :embed` reads
    # `engine.embed_retry_cap`; the pipeline's caller-side retry stays a new
    # job row sharing the idem key (J-IDEM, unchanged — the governor never
    # touches embed_jobs).
    class RetryGovernor
      # The backoff base (seconds). The design pins the SHAPE
      # (`rand · min(cap, base · 2^attempt)`) and the CAPS (engine_config);
      # the base is the loop's own constant.
      BASE_DELAY_S = 0.5
      # The backoff cap (seconds) — the per-attempt sleep ceiling.
      MAX_DELAY_S = 30

      # class → engine_config cap key. `site: :embed` overrides the cap with
      # `engine.embed_retry_cap` (FM-23's shared-class law).
      RETRY_CLASSES = {
        timeout:      "engine.transport_retry_cap",
        connection:   "engine.transport_retry_cap",
        stream:       "engine.stream_retry_cap",
        rate_limit:   "engine.rate_limit_retry_cap",
        server_error: "engine.server_error_retry_cap"
      }.freeze

      # The classes whose exhaustion is an operator-visible condition — L3
      # escalation pauses the quest (never a silent loop).
      PAUSE_ON_EXHAUSTION = %i[rate_limit].freeze

      attr_reader :attempts

      def initialize(conn:, config:, supervisor: nil, sleeper: nil, random: Random)
        @conn = conn
        @config = config
        @supervisor = supervisor # the E-PAUSE primary enforcement point
        @sleeper = sleeper       # test injection over Kernel#sleep
        @random = random
        @attempts = Hash.new(0)  # [site, class, session_id] → attempts this process
        @last_attempt = {}       # session_id → {fingerprint:, seed:} — FM-03's guard
      end

      # The failure-table's signature → class mapping (the gem's frozen error
      # taxonomy). ContextLengthExceededError is NOT retried here — it is the
      # ContextBudgeter's budget-guard (FM-09). Unknown raises are terminal
      # (never a speculative retry).
      def class_for(error)
        case error
        when Fast::Completions::ContextLengthExceededError then :context_length
        when Fast::Completions::TimeoutError then :timeout
        when Fast::Completions::ConnectionError then :connection
        when Fast::Completions::RateLimitError then :rate_limit
        when Fast::Completions::ServerError then :server_error
        when Fast::Completions::StreamError then :stream
        else :terminal
        end
      end

      # The bound for a class: the engine_config cap, `site: :embed` for the
      # embed call site (FM-23).
      def cap_for(class_name, site: :llm)
        key = site == :embed ? "engine.embed_retry_cap" : RETRY_CLASSES.fetch(class_name)
        Engine.config_value(@config, key)
      end

      # One retry step: FM-03's guard (an identical (body, seed) re-attempt is
      # REFUSED — structurally impossible via the decorator, refused here as
      # the complement), the jittered backoff, then the attempt count. Raises
      # `Engine::Error` (bank + loud phase-attempt failure) when the class is
      # exhausted — the caller banks and escalates.
      def retry!(class_name, session:, fingerprint:, seed:, site: :llm)
        key = [site, class_name, session.fetch(:id)]
        last = @last_attempt[session.fetch(:id)]
        if last && last[:fingerprint] == fingerprint && last[:seed] == seed
          raise Error, "retry refused: an identical (body, seed) re-attempt is the FM-03 replay " \
                       "mechanism — every retry carries a fresh seed (E-SEED)"
        end
        @last_attempt[session.fetch(:id)] = {fingerprint: fingerprint, seed: seed}

        @attempts[key] += 1
        cap = cap_for(class_name, site: site)
        if @attempts[key] > cap
          exhausted!(class_name, session)
        end
        @sleeper ? @sleeper.call(backoff_s(@attempts[key])) : sleep(backoff_s(@attempts[key]))
        @attempts[key]
      end

      def exhausted?(class_name, session:, site: :llm)
        @attempts[[site, class_name, session.fetch(:id)]] >= cap_for(class_name, site: site)
      end

      def backoff_s(attempt)
        @random.rand * [MAX_DELAY_S, BASE_DELAY_S * 2**attempt].min
      end

      # L2: the session banked at the turn boundary — `ended_at` stamped
      # (committed mutations survive) and the bank recorded in the phase
      # result. The `phases.attempt_no` count has ONE writer — the
      # empty-completion retry path (FM-01, the driver); the bank never
      # double-counts it.
      def bank_session!(session_id:, phase_id:, reason:)
        now = Time.now
        @conn[:sessions].where(id: session_id, ended_at: nil).update(ended_at: now)
        @conn[:phases].where(id: phase_id)
                      .update(result: Sequel.lit("coalesce(result, '{}'::jsonb) || ?::jsonb",
                                                 JSON.generate(banked: true, reason: reason,
                                                               banked_at: now.utc.iso8601)))
        nil
      end

      # L3: escalation-to-pause (delegated to the SessionSupervisor — the
      # ledgered `active → paused` transition's primary enforcement point).
      def pause_quest!(user_id:, quest_id:, actor: "orchestrator", note:)
        if @supervisor
          @supervisor.pause_quest!(user_id: user_id, quest_id: quest_id, actor: actor, note: note)
        else
          raise Error, "no pause path configured — L3 escalation requires the SessionSupervisor " \
                       "(the ledgered active → paused transition's primary enforcement point)"
        end
        nil
      end

      private

      def exhausted!(class_name, session)
        if PAUSE_ON_EXHAUSTION.include?(class_name)
          pause_quest!(user_id: session.fetch(:user_id), quest_id: session.fetch(:quest_id),
                       note: "retry cap exhausted: #{class_name} — a rate-limited provider is an " \
                             "operator-visible condition, not a loop problem (FM-07)")
        end
        raise Error, "#{class_name} retry cap exhausted for session #{session.fetch(:id)} — " \
                     "bank the session and end the phase attempt loudly (never a silent loop)"
      end
    end
  end
end
