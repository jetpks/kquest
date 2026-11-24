# frozen_string_literal: true

require_relative "../test_helper"

# The minted handle (I11 Part 2): AuthenticateUser mints a deterministic,
# ck_users_handle-legal handle from the github uid; find-or-create stays
# keyed on github_uid (two sign-ins mint ONE user).
class AuthenticateUserHandleTest < Minitest::Test
  def conn
    @conn ||= Kquest::App["db.gateway"].connection
  end

  def operation
    @operation ||= Kquest::App["operations.authenticate_user"]
  end

  def auth(uid:)
    info = Struct.new(:nickname, :name, :email, :image)
                 .new("octocat", "The Octocat", "octocat@example.com",
                      "https://example.com/avatar.png")
    OmniAuth::AuthHash.new(uid: uid, info: info)
  end

  def setup
    conn[:users].where(github_uid: "1900929").delete
  end

  def teardown
    conn[:users].where(github_uid: "1900929").delete
  end

  def test_minted_handle_matches_the_slug_regex
    user = operation.call(auth(uid: "1900929"))
    assert_match(/\A[a-z0-9][a-z0-9_-]{1,31}\z/, user.handle)
  ensure
    conn[:users].where(github_uid: "1900929").delete if user
  end

  def test_minted_handle_is_deterministic_from_the_uid
    user = operation.call(auth(uid: "1900929"))
    assert_equal "gh-1900929", user.handle
  ensure
    conn[:users].where(github_uid: "1900929").delete if user
  end

  # Find-or-create is still keyed on github_uid: the second sign-in updates
  # the same row (and the handle mint is idempotent), never a second user.
  def test_two_sign_ins_mint_one_user
    first  = operation.call(auth(uid: "1900929"))
    second = operation.call(auth(uid: "1900929"))
    assert_equal first.id, second.id
    assert_equal 1, conn[:users].where(github_uid: "1900929").count
  ensure
    conn[:users].where(github_uid: "1900929").delete if first
  end
end
