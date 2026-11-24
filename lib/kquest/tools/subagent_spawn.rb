# frozen_string_literal: true

module Kquest
  module Tools
    # Delegate to the landed SubagentRunner (I04 §6): profile gate, band
    # pairwise-disjoint union check, RETURNS IMMEDIATELY with the run id
    # (the frozen answer shape + the verify-with recipe). The frozen
    # profile-unknown / band-overlap texts are THIS tool's fixture classes —
    # the tool checks first, then hands the validated spawn to the runner.
    class SubagentSpawn < Base
      tool_name "subagent_spawn"

      parameters do
        {"type" => "object",
         "properties" => {"profile" => {"type" => "string"},
                          "band" => {"type" => "array", "items" => {"type" => "string"}},
                          "brief" => {"type" => "string"}},
         "required" => %w[profile brief]}
      end

      def execute(**args)
        profile = args[:profile].to_s
        tools = Kquest::Tools.profile_tools(conn, profile)
        refuse("subagent_spawn", "profile-unknown",
               named: "PROFILE-UNKNOWN: #{profile}") unless tools

        band = args[:band]
        check_band_disjoint!(band)

        run_id = @runner.spawn(parent_session: session, profile: profile, tools: tools,
                               runnable: ->(_session) { nil }, band: band)
        "subagent_spawn: run=#{run_id} profile=#{profile} band=#{band_label(band)} spawned (detached) " \
          "— verify with {\"tool\":\"subagent_status\",\"run\":\"#{run_id}\"}"
      end

      private

      # The band-survey spawn law (I04 DR-10): bands are pairwise disjoint.
      # The frozen band-overlap text names the overlapping segment + the
      # re-partition recipe; the runner's own check stays as the
      # defense-in-depth backstop.
      def check_band_disjoint!(band)
        return if band.nil?

        mine_lo = band.fetch(0).to_s[/\d+/].to_i
        mine_hi = band.fetch(1, band.fetch(0)).to_s[/\d+/].to_i
        # the sibling bands stay reserved across the round (any registered run)
        @runner.registry.values.select { |r| r.band }.each do |run|
          theirs_lo = run.band.fetch(0).to_s[/\d+/].to_i
          theirs_hi = run.band.fetch(1, run.band.fetch(0)).to_s[/\d+/].to_i
          overlap_start = [mine_lo, theirs_lo].max
          overlap_end = [mine_hi, theirs_hi].min
          if overlap_start <= overlap_end
            refuse("subagent_spawn", "band-overlap",
                   overlap: "overlaps K#{overlap_start}–K#{overlap_end}")
          end
        end
      end

      def band_segment(band)
        first = band.fetch(0).to_s
        last = band.fetch(1, first).to_s
        "#{first}–#{last}"
      end

      def band_label(band)
        return "none" unless band

        first = band.fetch(0).to_s
        last = band.fetch(1, first).to_s
        "K#{first[/\d+/]}–K#{last[/\d+/]}"
      end
    end
  end
end
