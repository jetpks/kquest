# frozen_string_literal: true

require "fast/embeddings"

module Kquest
  module Pipeline
    # The fast-embeddings seam. The registry row's `endpoint` is the FULL
    # wire endpoint (I03 seed law); the gem's client POSTs `{base}/embeddings`
    # ITSELF — so the client's base_url is the PARENT, derived by the explicit
    # `/embeddings`-suffix deletion below (a wrong seam sends
    # `POST {endpoint}/embeddings` and 404s). No kquest concept crosses the
    # seam; no retry machinery (the worker's single pass is the law — the
    # caller's retry is a NEW job row sharing the idem key).
    module Wire
      SUFFIX = "/embeddings"

      module_function

      def base_url_for(endpoint)
        unless endpoint.end_with?(SUFFIX)
          raise Error, "registry endpoint must end in #{SUFFIX.inspect} (it is the FULL wire " \
                       "endpoint; the client appends the path itself): #{endpoint.inspect}"
        end

        endpoint.delete_suffix(SUFFIX)
      end

      def client_for(model_row)
        ::Fast::Embeddings::Client.new(base_url: base_url_for(model_row[:endpoint]))
      end
    end
  end
end
