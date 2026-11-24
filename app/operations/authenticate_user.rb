# frozen_string_literal: true

module Kquest
  module Operations
    # Find-or-create a User from an OmniAuth auth hash (the provider claims
    # arrive in auth.info; the uid is the stable key). Faithful port of
    # User.from_omniauth from the Rails oracle, minus the org-membership
    # sync — that was domain authz and died with the authorize_user seam.
    class AuthenticateUser
      include Kquest::Deps["repos.users_repo"]

      def call(auth)
        find_or_create(auth)
      end

      private

      # The unified users table's `handle` is law (ck_users_handle: the slug
      # regex ^[a-z0-9][a-z0-9_-]{1,31}$, uq_users_handle UNIQUE). Minted
      # deterministically from the uid — the stable unique key — so handle is
      # unique in its minted domain; the insert fails loudly on a (truncation)
      # collision rather than silently coercing. "gh-" + up to 29 slug chars
      # stays within the regex's 32-char ceiling.
      def mint_handle(uid)
        "gh-" + uid.downcase.gsub(/[^a-z0-9_-]/, "-")[0, 29]
      end

      def find_or_create(auth)
        uid  = auth.uid.to_s
        info = auth.info
        now  = Time.now
        attrs = {
          username:   info.nickname,
          name:       info.name,
          email:      info.email,
          avatar_url: info.image,
          updated_at: now
        }

        if (existing = users_repo.by_github_uid(uid))
          users_repo.update(existing.id, attrs)
          users_repo.by_pk(existing.id)
        else
          users_repo.create(attrs.merge(github_uid: uid, handle: mint_handle(uid), created_at: now))
        end
      end
    end
  end
end
