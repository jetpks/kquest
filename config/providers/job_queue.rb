# frozen_string_literal: true

require "async/job/processor/inline"
require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"

# The queue the actions enqueue onto: Inline (runs the job body in-request) in
# test, the redis processor (a worker process dequeues) otherwise. Both ride
# Kquest::Jobs::Delegate — one queue, one worker, many bodies (the embed
# pipeline's "embed_job_id" rows and the substrate's "document_id" example
# share the same Delegate).
Hanami.app.register_provider(:job_queue) do
  start do
    delegate = Kquest::Jobs::Delegate.new

    processor = if Hanami.env?(:test)
      Async::Job::Processor::Inline.new(delegate)
    else
      Kquest::Jobs::Delegate.build_redis_processor
    end

    register("job_queue", processor)
  end
end
