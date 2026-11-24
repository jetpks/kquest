# frozen_string_literal: true

module Kquest
  module Pipeline
    # The content-address alphabet (I01 DR-02): Bitcoin base58 encode of a
    # byte string, one leading '1' per leading zero byte. Pure. Cross-checked
    # against the design corpus's own SQL re-derivation: the I01 seed's s1
    # fixture yields urn `kb:src:G4QeEUXJeL` through exactly this code.
    module Base58
      ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

      module_function

      def encode(bytes)
        # Leading zero bytes each encode as '1' (the numeric value of the
        # whole string carries no information about them).
        leading_zeros = bytes.bytes.take_while(&:zero?).size
        num = bytes.unpack1("H*").to_i(16)
        digits = +""
        while num > 0
          digits << ALPHABET[num % 58]
          num /= 58
        end
        "1" * leading_zeros + digits.reverse
      end
    end
  end
end
