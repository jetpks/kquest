# frozen_string_literal: true

require "json"
require "kernel/sync"
require "async/http"
require "uri"

module Kquest
  module Tools
    # The Exa-shaped web wire seam (I14 Part 4): resolves the `web_providers`
    # row by the `tools.web_provider` tool_config text_value (absent → a LOUD
    # operational error naming the config key + how to configure — an
    # operational misconfiguration, not a frozen fixture class), then speaks
    # the search/fetch wire to the row's base_url with KeyRef-resolved auth.
    # NO endpoint/provider literal anywhere in code — the provider row is the
    # wire (the ProviderDesk/registry posture); tests mock it with
    # test/support/mock_exa_server.rb + an upserted web_providers row.
    module WebWire
      module_function

      # The provider row (config-resolved, never hardcoded).
      def provider_row(conn)
        name = conn[:tool_config].where(key: "tools.web_provider").first &&
               Kquest::Queries.config_value(conn, "tools.web_provider")
        unless name
          raise Kquest::Engine::Error,
                "no web provider configured — set tool_config key 'tools.web_provider' to the " \
                "name of a web_providers row (base_url + optional api_key_ref); web tools wire " \
                "through config rows the way the registry wires embed models"
        end

        row = conn[:web_providers].where(name: name).first
        unless row
          raise Kquest::Engine::Error,
                "tool_config 'tools.web_provider' names '#{name}' but no web_providers row carries " \
                "that name — mint the row (name, base_url, api_key_ref) or point the key at one"
        end
        row
      end

      def api_key_for(row)
        Kquest::Pipeline::KeyRef.resolve(row.fetch(:api_key_ref))
      end

      # The search wire: POST {base_url}/search {query, numResults} — the
      # provider row's `params` jsonb merges as extra body keys (per-provider
      # wire parameters).
      def search(row, query:, max_results:)
        body = {"query" => query, "numResults" => max_results}
        body = body.merge(row.fetch(:params) || {})
        response = post(row, "search", body)
        parsed = JSON.parse(response)
        parsed["results"].map do |r|
          {"url" => r["url"], "title" => r["title"], "text" => r["text"]}
        end
      end

      # The fetch wire: POST {base_url}/contents {urls: [url]} — the reply's
      # first entry carries the page text.
      def fetch(row, url:)
        parsed = JSON.parse(post(row, "contents", {"urls" => [url]}))
        entry = parsed["results"].first
        raise Kquest::Pipeline::Error, "the fetch wire returned no content for #{url.inspect}" unless entry

        {"url" => entry["url"] || url, "title" => entry["title"] || url,
         "text" => entry["text"] || ""}
      end

      def post(row, path, body)
        run do
          endpoint = Async::HTTP::Endpoint.parse(row.fetch(:base_url))
          client = Async::HTTP::Client.new(endpoint)
          begin
            headers = {"content-type" => "application/json", "accept" => "application/json"}
            if (key = api_key_for(row))
              headers["authorization"] = "Bearer #{key}"
            end
            response = client.post("/#{path}", headers: headers, body: JSON.generate(body))
            unless (200...300).cover?(response.status)
              raise Kquest::Pipeline::Error, "web wire returned #{response.status} for #{path}"
            end

            response.body.join
          ensure
            client.close
          end
        end
      end

      # The wire runs in the caller's reactor when there is one (the loop's
      # tool calls always are); a direct execute (tests, the calibration
      # shape) gets its own — the Enqueue.push pattern.
      def run
        if Async::Task.current?
          yield
        else
          Sync { yield }
        end
      end
    end
  end
end
