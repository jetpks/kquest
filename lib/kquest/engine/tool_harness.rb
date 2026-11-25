# frozen_string_literal: true

require "json"

module Kquest
  module Engine
    # The dispatch contract (I04 §2.4, R-039/R-044): registers the session's
    # legal tool classes into `Chat#with_tools` (for subagent sessions the
    # profile's restricted list — the registration IS the restriction,
    # I05 §8) and wraps every `execute` with:
    #   (a) the same-transaction audit write (`tool_calls` row in the SAME
    #       transaction as the mutation — the transaction shape is THIS
    #       harness-owned Sequel transaction the tool's writes join);
    #   (b) the per-call deadline watchdog (FM-04: TERM → grace → liveness →
    #       KILL wherever subprocesses exist — day one the deadline cancels
    #       the tool's task and returns the LOUD teaching refusal);
    #   (c) result-size caps (truncation WITH a teaching note — the per-tool
    #       cap values are I05 R-052/I14's; the mechanism lands here);
    #   (d) budget guards (the seam; web-call counting is I14's tools);
    #   (e) the write-guard recheck before every mutation batch (FM-16
    #       defense-in-depth — the supervisor supplies the gate recheck).
    # Unknown tool names are intercepted BEFORE the gem's look-up (the
    # before-tool hook fires for every call): the call is routed to an
    # in-harness sink that returns the frozen teaching refusal (the frozen
    # `harness.md` `unknown-tool` text, byte-matched by the tests) and is
    # audited like any refusal; 3 consecutive unknown-tool calls escalate a
    # wedge-guard alert (`engine.unknown_tool_alert_at`, FM-12).
    class ToolHarness
      # The three frozen dispatch-contract texts (I05
      # artifacts/fixtures/harness.md). The TESTS parse the frozen fixture at
      # runtime and byte-compare these — the fixture is the law of record,
      # these constants are the implementation; drift is a test failure.
      UNKNOWN_TOOL_TEXT = "REFUSAL: no such tool: <name> — this session's legal tools: <legal-tools>; " \
                          "call one of those (the tool name IS the operation; there is no op key)"
      WRITE_GUARD_TEXT = "REFUSAL: WRITE-GUARD: quest <quest-id> is held by live writer session " \
                         "<session-id> (driver <driver>) — pause-and-resume to take over; this session " \
                         "may not mutate (one active writer per quest)"
      TOOL_DEADLINE_TEXT = "REFUSAL: TOOL-DEADLINE: <tool> exceeded tool_timeout_s (elapsed 120s; ran: " \
                           "source_grep pattern=… src=C13) — narrow the request (smaller range, " \
                           "narrower pattern, fewer rows) and retry; the session is alive and routes " \
                           "around it"

      # The unknown-tool interception sink's dispatch name (the before-hook
      # rewrites the call's name to this; the arguments gain the original
      # name under a reserved key — the assistant history block itself is
      # never mutated).
      class UnknownToolRefusal
        NAME = "kquest_unknown_tool_refusal"
        KEY = :__unknown_tool

        def initialize(harness) = @harness = harness

        def name = NAME
        def description = "No registered tool matches a call routed here; returns the session's " \
                          "teaching refusal naming the legal tools."
        def parameters = {"type" => "object", "properties" => {}}

        def execute(**args)
          original = args.delete(KEY).to_s
          {error: @harness.unknown_tool_refusal(original)}
        end
      end

      # The per-tool wrapper the gem sees: declaration readers forward; the
      # execute goes through the harness (deadline + audit + caps + guards).
      class HarnessedTool
        def initialize(tool, harness)
          @tool = tool
          @harness = harness
        end

        def name = @tool.name
        def description = @tool.description
        def parameters = @tool.parameters

        def constrained_sampling
          @tool.respond_to?(:constrained_sampling) ? @tool.constrained_sampling : nil
        end

        def mutates?
          @tool.respond_to?(:mutates?) ? !!@tool.mutates? : false
        end

        def execute(**args)
          # An intercepted unknown call audits under the name the MODEL called.
          audit_name = args.key?(UnknownToolRefusal::KEY) ? args[UnknownToolRefusal::KEY].to_s : name
          @harness.invoke(@tool, audit_name: audit_name, **args)
        end

        def respond_to_missing?(name, include_private = false)
          @tool.respond_to?(name, include_private) || super
        end

        def method_missing(name, *args, **kwargs, &block)
          if @tool.respond_to?(name)
            @tool.public_send(name, *args, **kwargs, &block)
          else
            super
          end
        end
      end

      # The mechanism's result cap (bytes of rendered content) — per-tool cap
      # VALUES are I05 R-052/I14's; this default serves until then.
      DEFAULT_RESULT_CAP_BYTES = 50_000
      CAP_NOTE = "\n[RESULT CAP: the result exceeded the cap and was TRUNCATED with this teaching " \
                 "note — never a silent truncation; narrow the request (fewer rows, smaller range, " \
                 "tighter pattern) and retry]"

      attr_reader :legal_names

      def initialize(conn:, session:, ledger:, config:, write_guard: nil, budgeter: nil,
                     watch: nil, result_cap: DEFAULT_RESULT_CAP_BYTES, deadline_sleeper: nil)
        @conn = conn
        @session = session
        @ledger = ledger
        @config = config
        @write_guard = write_guard # the supervisor's gate recheck (raises on a live holder)
        @budgeter = budgeter
        @watch = watch
        @result_cap = result_cap
        @tool_timeout = Engine.config_value(config, "engine.tool_timeout_s")
        @alert_at = Engine.config_value(config, "engine.unknown_tool_alert_at")
        @deadline_sleeper = deadline_sleeper # test injection over Kernel#sleep
        @names = {}
        @unknown_streak = 0
        @alerts = []
      end

      attr_reader :alerts

      # Registers the session's legal surface (restricted for subagents — the
      # registration IS the restriction) plus the unknown-tool interception.
      def register!(chat, tools:)
        # Tool classes or instances (the gem's with_tools convention) — a
        # class instantiates (its default ctor takes no args); a class object
        # would collide with Ruby's Module#name in dispatch.
        instances = tools.map { |tool| tool.is_a?(Class) ? tool.new : tool }
        harnessed = instances.map { |tool| HarnessedTool.new(tool, self) }
        harnessed << HarnessedTool.new(UnknownToolRefusal.new(self), self)
        @names = harnessed.to_h { |tool| [tool.name, tool] }
        @legal_names = instances.map(&:name).freeze
        chat.with_tools(*harnessed)
        chat.before_tool_call { |tool_call| intercept_unknown!(tool_call) }
        chat
      end

      # The frozen `unknown-tool` teaching refusal (FM-12).
      def unknown_tool_refusal(name)
        UNKNOWN_TOOL_TEXT.gsub("<name>", name.to_s)
                         .gsub("<legal-tools>", @legal_names.join(", "))
      end

      # The frozen `tool-deadline` teaching refusal (FM-04): the elapsed and
      # ran segments are the template's substitution points.
      def tool_deadline_refusal(tool_name, elapsed_s, ran)
        TOOL_DEADLINE_TEXT.gsub("<tool>", tool_name.to_s)
                          .sub(/elapsed \d+s/, "elapsed #{elapsed_s}s")
                          .sub(/ran: [^)]+\)/, "ran: #{ran})")
      end

      def alerts?
        !@alerts.empty?
      end

      # ── the wrapped execution (the gem calls HarnessedTool#execute) ────

      def invoke(tool, audit_name:, **args)
        return tool_arguments_failure!(audit_name) if marker_arguments?(args)

        outcome = nil
        error_class = nil
        refused = false
        @conn.transaction do
          raw = begin
            # F4 (I20): the tool's own writes run in a SAVEPOINT nested in the
            # outer transaction — a server-side SQL failure inside the tool
            # rolls back to the savepoint and raises at its release, so these
            # rescue arms stay OUTSIDE the savepoint block and the audit!
            # below still lands in the healthy outer transaction (L8).
            @conn.transaction(savepoint: true) do
              guard_mutation! if tool.respond_to?(:mutates?) && tool.mutates?
              @budgeter&.tool_budget_check!(audit_name)
              with_deadline(audit_name, ran_description(tool, args)) { tool.execute(**args) }
            end
          rescue Kquest::Engine::Error => e # a refusal is an in-band teaching result, never a wedge
            refused = true
            error_class = e.error_class
            {error: e.message}
          rescue Fast::Completions::CancelledError, Async::Cancel
            raise # a cancel is never a tool result (FM-19; the batch re-raises)
          rescue ArgumentError
            raise # re-raises OUT of the batch — a dispatch-boundary defect is terminal
          rescue StandardError => e
            error_class = e.class.name
            {error: e.message.to_s} # failure isolation to THIS call
          end
          audit!(audit_name, args, raw, ok: !refused && error_class.nil?, error_class: error_class)
          outcome = raw
          @budgeter&.record_ingestion!(outcome)
        end
        apply_cap(outcome)
      end

      private

      # FM-11: a tool_call whose arguments finalize to the
      # ToolArgumentsFailure marker NEVER executes — the marker converts to
      # that call's is_error result carrying the marker message verbatim
      # (audited), and the model re-calls.
      def marker_arguments?(args)
        Fast::Completions::ToolArgumentsFailure.marker?(args)
      end

      def tool_arguments_failure!(audit_name)
        message = Fast::Completions::ToolArgumentsFailure::MESSAGE
        @conn.transaction do
          @ledger.record_tool_call!(tool: audit_name, args: {},
                                    result: {content: message, is_error: true},
                                    ok: false, error_class: "ToolArgumentsFailure")
        end
        {error: message}
      end

      private

      # FM-16 defense-in-depth: the write-guard recheck before every mutation
      # batch. A raise rolls the transaction back (nothing written) and
      # surfaces the frozen refusal.
      def guard_mutation!
        @write_guard&.call
        nil
      end

      # FM-04: the per-call deadline. The tool's task is cancelled past the
      # deadline (TERM → grace → liveness → KILL wherever subprocesses exist
      # — pgroup hygiene is the subprocess site's obligation); a USER cancel
      # (fired == false) passes through untouched — never a fake refusal.
      def with_deadline(tool_name, ran)
        task = Async::Task.current
        fired = false
        timer = task.async do
          deadline_sleep(@tool_timeout)
          fired = true
          task.cancel
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          yield
        rescue Async::Cancel
          raise unless fired # the user's cancel is never a tool refusal

          raise Error.new(tool_deadline_refusal(tool_name, elapsed_s(started), ran),
                          error_class: "ToolDeadline")
        ensure
          timer.stop
        end
      end

      def deadline_sleep(seconds) = @deadline_sleeper ? @deadline_sleeper.call(seconds) : sleep(seconds)

      def elapsed_s(started)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        elapsed.ceil
      end

      # What ran (the teaching refusal's ran segment): the tool's own
      # description of its invocation when it declares one, else the args.
      def ran_description(tool, args)
        return tool.ran_description(**args) if tool.respond_to?(:ran_description)

        args.reject { |k, _| k.to_s.start_with?("__") }.to_s[0, 120]
      end

      # The audit row (E-AUDIT/T-AUDIT): same transaction as the mutation,
      # refusals included, ok/error shape law per I01.
      def audit!(tool, args, raw, ok:, error_class:)
        shown_args = args.reject { |k, _| k.to_s.start_with?("__") }
        @ledger.record_tool_call!(
          tool: tool, op: args[:op],
          args: shown_args,
          result: audit_result(raw), ok: ok, error_class: error_class
        )
        rendered = audit_result(raw)
        @ledger.record_tool_result!(tool: tool, args: shown_args,
                                    content: rendered[:content], is_error: rendered[:is_error])
        nil
      end

      # The model-visible result, verbatim: the gem renders Hash outcomes as
      # JSON content and {error:}-only outcomes as error content.
      def audit_result(raw)
        if raw.is_a?(Hash) && raw.keys == [:error]
          {content: raw[:error].to_s, is_error: true}
        elsif raw.is_a?(Hash)
          {content: JSON.generate(raw), is_error: false}
        else
          {content: raw.to_s, is_error: false}
        end
      end

      # Result caps: truncation WITH the teaching note, never silent (I04
      # §2.4 — the PoC's result-economy lesson).
      def apply_cap(outcome)
        if outcome.is_a?(Hash) && outcome.keys == [:error]
          return outcome if outcome[:error].to_s.bytesize <= @result_cap

          {error: outcome[:error].to_s.byteslice(0, @result_cap) + CAP_NOTE}
        elsif outcome.is_a?(String)
          return outcome if outcome.bytesize <= @result_cap

          outcome.byteslice(0, @result_cap) + CAP_NOTE
        else
          outcome
        end
      end

      # FM-12: unknown names are intercepted (the before hook fires for every
      # call, the gem's look-up happens after); the call routes to the sink
      # tool which returns the frozen refusal. 3 consecutive unknowns = a
      # wedge-guard alert (a stuck model, not a bad call).
      def intercept_unknown!(tool_call)
        name = tool_call[:name]
        if @names.key?(name)
          @unknown_streak = 0
          return
        end

        @unknown_streak += 1
        if @unknown_streak >= @alert_at
          alert = {type: "wedge_guard", tool: name.to_s,
                   message: "WEDGE-GUARD: #{@unknown_streak} consecutive unknown-tool calls " \
                            "(last: #{name.inspect}) — a stuck model, not a bad call; " \
                            "the session's legal surface teaches on every refusal"}
          @alerts << alert
          @watch&.signal(:unknown_tool_storm, alert[:message])
        end

        # The gem's Phase-A hook receives a FRESH tool_call Hash; rewriting
        # name/arguments here never touches the assistant history block
        # (arguments is replaced by reference, not mutated).
        tool_call[:name] = UnknownToolRefusal::NAME
        tool_call[:arguments] = (tool_call[:arguments] || {}).merge(UnknownToolRefusal::KEY => name.to_s)
        nil
      end
    end
  end
end
