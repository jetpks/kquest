# frozen_string_literal: true

module Kquest
  class Routes < Hanami::Routes
    mount HanamiHealthcheck::Endpoint.new, at: "/up"

    # Auth — OmniAuth callback (GET for redirect, POST for form submission)
    get  "/auth/:provider/callback", to: "sessions.create"
    post "/auth/:provider/callback", to: "sessions.create"
    get  "/auth/failure",            to: "sessions.failure"

    # Logout — both GET (link) and DELETE (form)
    get    "/logout", to: "sessions.destroy"
    delete "/logout", to: "sessions.destroy"

    # The shell's root landing page
    root to: "home.index"
  end
end
