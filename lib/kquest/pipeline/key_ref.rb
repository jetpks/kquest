# frozen_string_literal: true

module Kquest
  module Pipeline
    # The api_key_ref resolver: `env:<NAME>` reads ENV[<NAME>] (unset → loud
    # error); NULL/empty → nil (a local engine needs no credential — the wire
    # client then sends no Authorization header); any other form → loud
    # refusal (ProviderDesk, ENTRY 3, owns the general surface). Never a
    # secret in code or logs — values live only in the caller's local.
    module KeyRef
      module_function

      def resolve(ref)
        return nil if ref.nil? || ref.empty?

        unless ref.match?(/\Aenv:[A-Za-z_][A-Za-z0-9_]*\z/)
          raise Error, "unsupported api_key_ref form: #{ref.inspect} " \
                       "(only `env:<NAME>` is resolved here; ProviderDesk owns the general surface)"
        end

        name = ref.delete_prefix("env:")
        value = ENV[name]
        return value unless value.nil? || value.empty?

        raise Error, "api_key_ref #{ref.inspect}: environment variable #{name} is not set"
      end
    end
  end
end
