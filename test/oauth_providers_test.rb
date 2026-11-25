# frozen_string_literal: true

require_relative "test_helper"

# The settings-driven OAuth provider seam (BRIEF §4): settings.oauth_providers
# names the enabled providers; both the OmniAuth registration and the CSP
# form-action origins derive from that same list (config/app.rb). github is the
# compiled-in example strategy. (Bare OmniAuth.strategies can't prove the mount
# — merely requiring omniauth-github appends the class to that list — so the
# seam is asserted at its source.)
class OauthProvidersTest < Minitest::Test
  def settings = Kquest::App["settings"]

  def test_default_settings_enable_github_only
    assert_equal %w[github], settings.oauth_providers
  end

  def test_every_enabled_provider_resolves_to_a_strategy_registration
    settings.oauth_providers.each do |name|
      assert_includes Kquest::OAUTH_PROVIDERS, name
    end

    strategy, positional, kwargs =
      Kquest.oauth_provider_registration("github", settings)
    assert_equal :github, strategy
    # Credentials + options resolve through the map's settings keys as
    # POSITIONAL args (omniauth-oauth2's signature); nil in test env, where
    # none are configured — same values the seed captured at boot.
    client_id, client_secret, options = positional
    entry = Kquest::OAUTH_PROVIDERS.fetch("github")
    assert_equal :github_client_id,     entry[:client_id_setting]
    assert_equal :github_client_secret, entry[:client_secret_setting]
    assert_nil client_id
    assert_nil client_secret
    assert_equal({scope: "read:user,user:email,read:org"}, options)
    assert_empty kwargs
  end

  def test_csp_form_action_includes_every_enabled_provider_origin
    origins = Kquest.oauth_form_action_origins(settings.oauth_providers)
    assert_equal ["https://github.com"], origins

    # The live app CSP, as derived at boot from the same list.
    form_action = Kquest::App.config.actions.content_security_policy[:form_action]
    assert_includes form_action, "'self'"
    origins.each { |origin| assert_includes form_action, origin }
  end

  def test_unknown_provider_name_raises
    assert_raises(KeyError) { Kquest.oauth_provider_registration("gitlab", settings) }
    assert_raises(KeyError) { Kquest.oauth_form_action_origins(["gitlab"]) }
  end

  # The dev-only developer strategy: resolves like any provider (no client
  # credentials — the map carries nil settings keys), contributes no CSP
  # form-action origin (its form GETs our own callback), and refuses to
  # mount outside development.
  def test_developer_provider_resolves_without_credentials
    strategy, positional, kwargs =
      Kquest.oauth_provider_registration("developer", settings)
    assert_equal :developer, strategy
    # The base Strategy takes NO positional args (OmniAuth 2.4 raises on
    # leftovers) — credentials-less providers carry options as keywords only.
    assert_empty positional
    # fields line up with AuthenticateUser's expectations (username ←
    # info.nickname; uid ← email), so the callback stack runs unmodified.
    assert_equal({fields: %i[nickname email], uid_field: :email}, kwargs)
  end

  def test_developer_provider_adds_no_csp_form_action_origin
    origins = Kquest.oauth_form_action_origins(%w[github developer])
    assert_equal ["https://github.com"], origins
  end

  def test_developer_provider_refuses_to_mount_outside_development
    assert_developer_guard_raises(%w[github developer], :production)
    assert_developer_guard_raises(%w[developer], :test)
    # Development — and any list without developer, in any env — passes.
    Kquest.assert_developer_allowed!(%w[github developer], :development)
    Kquest.assert_developer_allowed!(%w[github], :production)
  end

  private

  def assert_developer_guard_raises(providers, env)
    error = assert_raises(RuntimeError) do
      Kquest.assert_developer_allowed!(providers, env)
    end
    assert_match(/developer.*outside development/, error.message)
  end
end
