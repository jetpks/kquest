# frozen_string_literal: true

module Kquest
  module Tools
    # The agent's self-orientation (I05 §2): quest/phase/writer state and the
    # three budget lines (advisory lines teach — this is where the agent
    # SEES the walls before it hits them). The frozen answer shape; the
    # three budget lines are DERIVED (usage_events rollups / the web-call
    # count) vs the quests budget columns; the parity fields are exactly the
    # §5 block's (T-GATE — no decorative fields).
    class QuestStatus < Base
      tool_name "quest_status"

      parameters { {"type" => "object", "properties" => {}} }

      def execute(**_args)
        f = Kquest::Queries::StatusSnapshot.new(conn: conn)
            .quest_fields(user_id: user_id, quest_id: quest_id, session_id: session.fetch(:id))
        self.class.line(f)
      end

      # The frozen `quest_status` line composition (I05 §5's parity law), shared
      # so the UI's echoes compose through THIS method — byte-faithfulness by
      # construction, never by copy (the I14 composed-constants precedent). The
      # token formats (web_calls=<used>/<cap>, SI-suffixed tokens, %.2f spend,
      # writer=session/<id4>) moved here verbatim from #execute. Absent session:
      # phase/writer degrade to `-` (the three budget lines + quest state are
      # always derivable and never depend on a session).
      def self.line(f)
        "quest_status: quest=#{f[:quest]} phase=#{f[:phase] || "-"} writer=#{f[:writer] || "-"} " \
          "web_calls=#{f[:web_used]}/#{f[:web_cap]} " \
          "tokens=#{format_tokens(f[:tokens_used])}/#{format_tokens(f[:tokens_cap])} " \
          "spend_usd=#{format("%.2f", f[:spend_used])}/#{format("%.2f", f[:spend_cap])}"
      end

      # The frozen shape's token format: 931k / 2.0M (SI-suffixed, one
      # decimal for millions).
      def self.format_tokens(n)
        n = n.to_i
        return n.to_s if n < 1000
        return "#{n / 1000}k" if n < 1_000_000

        format("%.1fM", n / 1_000_000.0)
      end
    end
  end
end
