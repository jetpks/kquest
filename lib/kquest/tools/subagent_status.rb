# frozen_string_literal: true

module Kquest
  module Tools
    # Poll a child run by id against the run registry (I04 FM-20): a missing
    # tool result NEVER implies a dead child (wedge #3 law); a missing run
    # id surfaces the frozen unknown-run refusal — the poller retries.
    class SubagentStatus < Base
      tool_name "subagent_status"

      parameters do
        {"type" => "object",
         "properties" => {"run" => {"type" => "string"}},
         "required" => ["run"]}
      end

      def execute(**args)
        run_id = args[:run].to_s
        status = @runner&.status(run_id)
        refuse("subagent_status", "unknown-run", run: run_id) if status == :unknown || status.nil?

        status = {profile: nil, band: nil}.merge(status)
        elapsed = (Time.now - status.fetch(:started_at, Time.now)).round
        if %w[complete failed deadline_exceeded].include?(status.fetch(:status))
          "subagent_status: #{run_id} profile=#{status.fetch(:profile)} " \
            "state=#{status.fetch(:status)} elapsed=#{elapsed}s" +
            (status.fetch(:error) ? " error=#{status.fetch(:error)}" : "")
        else
          "subagent_status: #{run_id} profile=#{status.fetch(:profile)} " \
            "state=#{status.fetch(:status)} elapsed=#{elapsed}s (poll again; digest lands on completion)"
        end
      end
    end
  end
end
