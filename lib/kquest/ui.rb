# frozen_string_literal: true

module Kquest
  # The UI substrate namespace (I16 Part 0): the shared visibility gate, the
  # L15 capped-listing helper + its telemetry, consumed by every read
  # surface. Zeitwerk autoloads `lib/kquest/**` — the files under `ui/`
  # define their own matching constants (directory files never
  # require_relative siblings).
  module Ui
  end

  # The frozen spec's spelling (`Kquest::UI::…`) rides an alias: the
  # inflector camelizes "ui" to "Ui", so the MATCHING constant is Kquest::Ui
  # (the sse.rb acronym precedent — SSE itself can't ride the autoloader for
  # the same reason). Both spellings resolve once this file loads.
  UI = Ui
end
