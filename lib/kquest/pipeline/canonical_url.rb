# frozen_string_literal: true

require "uri"

module Kquest
  module Pipeline
    # DR-03 Option A (operator-ratified) canonical URL normalization:
    # lowercase scheme/host, drop the default port, drop the fragment,
    # percent-normalize (decode unreserved, uppercase-hex reserved), remove
    # dot-segments, sort query params, strip the tracking-param list. NO
    # www-stripping, NO scheme rewriting.
    module CanonicalUrl
      # The tracking-param list, carried as a visible constant (config, not
      # code): `utm_*` by prefix, the rest exact.
      TRACKING_PREFIXES = ["utm_"].freeze
      TRACKING_PARAMS = %w[fbclid gclid msclkid mc_cid mc_eid ref ref_src].freeze

      UNRESERVED = /\A[A-Za-z0-9\-._~]\z/

      module_function

      def call(url)
        uri = URI.parse(url.to_s.strip)
        raise Error, "not an absolute http(s) URL: #{url.inspect}" unless uri.is_a?(URI::HTTP) && uri.host

        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = uri.default_port if uri.port == uri.default_port
        uri.fragment = nil
        uri.path = normalize_path(uri.path)
        uri.query = normalize_query(uri.query)
        uri.to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError => e
        raise Error, "unparseable URL: #{e.message}"
      end

      # RFC 3986 remove_dot_segments, then percent-normalize the escapes:
      # an unreserved byte decodes to itself; a reserved byte re-encodes
      # UPPERCASE-hex. Other bytes are left exactly as written.
      def normalize_path(path)
        path = remove_dot_segments(path)
        path.gsub(/%[0-9a-fA-F]{2}/) do |escape|
          byte = escape[1, 2].to_i(16).chr
          byte.match?(UNRESERVED) ? byte : "%#{escape[1, 2].upcase}"
        end
      end

      def remove_dot_segments(path)
        input = path.dup
        output = +""
        until input.empty?
          if input.start_with?("../", "./")
            input = input[3..]
          elsif input.start_with?("/./")
            input = input[2..]
          elsif input == "/."
            input = "/"
          elsif input.start_with?("/../")
            input = input[3..]
            output = output.sub(/\/[^\/]*\z/, "")
          elsif input == "/.."
            input = "/"
            output = output.sub(/\/[^\/]*\z/, "")
          elsif input in "." | ".."
            input = ""
          else
            segment = input.start_with?("/") ? input[/\A\/[^\/]*/] : input[/\A[^\/]*/]
            output << segment
            input = input[segment.length..]
          end
        end
        output.empty? ? "/" : output
      end

      def normalize_query(query)
        return nil if query.nil?

        pairs = URI.decode_www_form(query).sort_by { |name, value| [name, value] }
        pairs = pairs.reject { |name, _| tracking?(name) }
        return nil if pairs.empty?

        # Re-encode with the canonical component alphabet: unreserved bytes
        # stay literal, everything else UPPERCASE-hex (encode_www_form would
        # re-escape `~` — the unreserved set must round-trip decoded).
        pairs.map { |name, value| "#{encode_component(name)}=#{encode_component(value)}" }.join("&")
      rescue ArgumentError
        # Not a decodable query form — keep it verbatim minus tracking names.
        kept = query.split("&").reject { |pair| tracking?(pair.split("=", 2).first.to_s) }
        kept.empty? ? nil : kept.join("&")
      end

      def encode_component(str)
        str.gsub(/[^A-Za-z0-9\-._~]/) { |ch| "%" + ch.unpack1("H*").upcase }
      end

      def tracking?(name)
        TRACKING_PARAMS.include?(name) || TRACKING_PREFIXES.any? { |p| name.start_with?(p) }
      end
    end
  end
end
