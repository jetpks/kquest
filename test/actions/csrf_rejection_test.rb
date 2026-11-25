# frozen_string_literal: true

require_relative "../actions/action_test_helper"
require "json"

# The graceful CSRF rejection (I20 Part 9 / AC11, the I18/I19 queued item):
# Kquest::Action's handle_invalid_csrf_token override renders the teaching
# 403 + JSON body and HALTS — handle never runs on a rejected token
# (nothing lands), InvalidCSRFTokenError never escapes (no 500), and the
# session is NOT cleared (the no-session-clear sub-decision: a stale-token
# retry must not log the operator out). hanami-action exempts the whole CSRF
# module in the test env (config/app.rb), so the seam is reached DIRECTLY on
# a real action instance with constructed req/res objects; the LIVE proof is
# bin/live_receipt.sh script/csrf_rejection_receipt.sh (the dev server, CSRF
# active).
class CsrfRejectionTest < Minitest::Test
  include ActionTestHelper

  # A real action: the CSRF receipt's own door (POST /workspaces — PRG + flash
  # on success), a Kquest::Action subclass carrying the override.
  def action = Kquest::Actions::Dashboard::CreateWorkspace.new

  def csrf_flow
    env = Rack::MockRequest.env_for("/workspaces", "REQUEST_METHOD" => "POST")
    req = Hanami::Action::Request.new(env: env, params: {}, session_enabled: true)
    req.session[:_csrf_token] = "the-session-challenge-token"
    res = Hanami::Action::Response.new(request: req, config: Hanami::Action.config.dup,
                                       session_enabled: true)
    [req, res]
  end

  def test_handle_invalid_csrf_token_renders_the_teaching_403
    req, res = csrf_flow
    outcome = nil
    thrown = catch(:halt) do
      outcome = action.send(:handle_invalid_csrf_token, req, res)
      nil
    end

    assert_nil outcome, "the override HALTS — it never returns into handle"
    assert_equal 403, thrown[0], "a CSRF failure is a refusal (403), never the 500 class"
    assert_equal JSON.generate(error: Kquest::Action::CSRF_REJECTION_TEXT), thrown[1],
                 "the frozen teaching text byte-matched"
    assert_equal "application/json; charset=utf-8", res.content_type
  end

  def test_the_rejection_raises_nothing_and_never_clears_the_session
    req, res = csrf_flow

    # "raises nothing": a raise (the gem default's InvalidCSRFTokenError) or a
    # missing halt would fail this test — the catch observes the normal return
    # after the thrown halt tuple.
    thrown = catch(:halt) { action.send(:handle_invalid_csrf_token, req, res) }
    refute_nil thrown

    assert req.session.key?(:_csrf_token),
           "the session is NOT cleared — a stale-token retry must not log the operator out"
    assert_equal "the-session-challenge-token", req.session[:_csrf_token]
  end
end
