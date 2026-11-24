# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/pipeline_fixtures"

# DR-03 Option A canonicalization, one named property per frozen law.
class CanonicalUrlTest < Minitest::Test
  def test_scheme_host_downcase_default_port_drop_fragment_drop
    assert_equal "https://example.com/a/b",
      Kquest::Pipeline::CanonicalUrl.call("HTTPS://Example.COM:443/a/b#frag")
    assert_equal "http://example.com/x",
      Kquest::Pipeline::CanonicalUrl.call("http://example.com:80/x")
    # NO www-stripping, NO scheme rewriting.
    assert_equal "https://www.example.com/a",
      Kquest::Pipeline::CanonicalUrl.call("https://WWW.example.com/a")
  end

  def test_dot_segments_removed
    assert_equal "https://example.com/a/c",
      Kquest::Pipeline::CanonicalUrl.call("https://example.com/a/./b/../c")
    assert_equal "https://example.com/c",
      Kquest::Pipeline::CanonicalUrl.call("https://example.com/../c")
  end

  def test_tracking_strip_and_query_sort
    # The I01 seed's own demonstration: s2's url carries utm_source, its
    # canonical_url does not.
    assert_equal "https://fixture.example/momentum-primer",
      Kquest::Pipeline::CanonicalUrl.call("https://fixture.example/momentum-primer?utm_source=newsletter")
    # The full list + sort: params land name-sorted, tracking names gone.
    assert_equal "https://example.com/p?a=1&b=2&z=9",
      Kquest::Pipeline::CanonicalUrl.call("https://example.com/p?b=2&z=9&fbclid=zz&utm_campaign=x&a=1&gclid=y&mc_cid=1&mc_eid=2&ref=r&ref_src=s&msclkid=m")
  end

  def test_percent_normalization
    # Unreserved decodes; reserved re-encodes UPPERCASE-hex.
    assert_equal "https://example.com/a~b?x=%2F&y=~",
      Kquest::Pipeline::CanonicalUrl.call("https://example.com/a%7Eb?x=%2f&y=%7E")
  end
end
