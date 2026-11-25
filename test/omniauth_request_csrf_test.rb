# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"

# Regression guard for the OmniAuth request-phase CSRF check wired in config/app.rb.
#
# OmniAuth.config.request_validation_phase validates POST /auth/github against Hanami's
# own session :_csrf_token — the token every SPA form submits as the `_csrf_token`
# param (the ONE wire name, Hanami-native; renamed app-wide 2026-11-24 from the
# Rails-convention authenticity_token) / X-CSRF-Token — replacing OmniAuth's default
# rack-protection AuthenticityToken (a separate :csrf key the frontend never sends). A matching token
# passes; a missing or mismatched token raises OmniAuth::AuthenticityError, which routes
# to on_failure → /auth/failure. Driven directly (OmniAuth test_mode bypasses the request
# phase, so a full-stack POST would assert nothing).
class OmniAuthRequestCsrfTest < Minitest::Test
  TOKEN = "csrf-token-deadbeef0123456789"

  def validate(session:, _csrf_token: nil, header: nil)
    env = Rack::MockRequest.env_for(
      "/auth/github",
      method: "POST",
      params: _csrf_token ? {"_csrf_token" => _csrf_token} : {}
    )
    env["rack.session"] = session
    env["HTTP_X_CSRF_TOKEN"] = header if header
    OmniAuth.config.request_validation_phase.call(env)
  end

  def test_matching_form_token_passes
    assert_nil validate(session: {_csrf_token: TOKEN}, _csrf_token: TOKEN)
  end

  def test_matching_token_via_x_csrf_token_header_passes
    assert_nil validate(session: {_csrf_token: TOKEN}, header: TOKEN)
  end

  def test_string_keyed_session_token_passes
    # the session may round-trip through the cookie with a string key
    assert_nil validate(session: {"_csrf_token" => TOKEN}, _csrf_token: TOKEN)
  end

  def test_mismatched_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: TOKEN}, _csrf_token: "wrong-token")
    end
  end

  def test_missing_submitted_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: TOKEN})
    end
  end

  def test_missing_session_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {}, _csrf_token: TOKEN)
    end
  end

  def test_empty_strings_are_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: ""}, _csrf_token: "")
    end
  end
end
