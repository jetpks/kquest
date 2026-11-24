# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/managed/service"
require "async/service/managed/environment"

# Web service: serves the Rack app (config.ru) on plain HTTP.
#
# Falcon::Environment::Rack includes Application which overrides endpoint to a Unix IPC socket
# (designed for virtual-host reverse-proxy topology). We override endpoint to bind plain TCP HTTP
# so both the web service and the boot-smoke probe work without a separate proxy layer.
service "kquest.web" do
  include Falcon::Environment::Rack

  # FALCON_BIND: container deploys override (podman's PublishPort forwards to
  # the container's eth0, not its localhost — the image sets 0.0.0.0). Dev/test
  # default unchanged.
  endpoint { Async::HTTP::Endpoint.parse(ENV.fetch("FALCON_BIND", "http://localhost:3000")) }
end

# The WORKER TOPOLOGY (I08 DR-08 ruling A): the quest-worker launcher (which
# keeps exactly one quest worker per ACTIVE quest and hosts the assurance
# poller) and the singleton job worker, supervised by the SAME falcon
# controller as kquest.web. Enabled where the operator deploys workers —
# KQUEST_SUPERVISED_WORKERS — because the frozen falcon-configuration test
# pins the always-on service set to kquest.web alone (the suite never boots
# workers; see the builder report's PHASE 0 note 1). The service classes run
# the bin scripts' loops in-process inside the supervised containers (the
# static services host the DYNAMIC quest-worker churn through the launcher —
# the DR-08 sub-ruling).
if ENV["KQUEST_SUPERVISED_WORKERS"]
  # A generic supervised service: N container children each run one loop body
  # (the launcher's periodic loop / the job worker's dequeue loop).
  class KquestWorkerLoopService < Async::Service::Generic
    def initialize(environment, evaluator, &body)
      super(environment, evaluator)
      @body = body
    end

    def setup(container)
      Integer(@evaluator.count || 1).times do
        container.async(name: name) { @body.call }
      end
    end
  end

  service "kquest.quest-workers" do
    count Integer(ENV.fetch("KQUEST_QUEST_WORKER_LAUNCHERS", 1))

    make_service { |environment|
      KquestWorkerLoopService.new(environment, environment.evaluator) do
        require "hanami/boot"
        require_relative "bin/quest-worker-launcher"
      end
    }
  end

  service "kquest.job-worker" do
    count Integer(ENV.fetch("KQUEST_JOB_WORKERS", 1))

    make_service { |environment|
      KquestWorkerLoopService.new(environment, environment.evaluator) do
        require "hanami/boot"
        require_relative "bin/worker"
      end
    }
  end
end
