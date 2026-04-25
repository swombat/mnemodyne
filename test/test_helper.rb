# Run with: bin/rails test
# Embedding calls are stubbed; tests don't hit the network.
ENV["RAILS_ENV"] ||= "test"
ENV["AUTH_TOKEN"] ||= "test-token"
require_relative "../config/environment"
require "rails/test_help"

# Deterministic pseudo-embeddings for tests. Same text → same normalised
# vector. Different text → different vector. Cosine distances are meaningful
# within a test run.
module StubbedEmbedding
  class StubProvider
    def embed(text)
      seed = text.to_s.bytes.sum
      rng = Random.new(seed)
      vec = Array.new(Embeddings::Base.dimension) { rng.rand(-1.0..1.0) }
      norm = Math.sqrt(vec.sum { |v| v * v })
      norm.zero? ? vec : vec.map { |v| v / norm }
    end

    def embed_batch(texts) = texts.map { |t| embed(t) }
  end
end

module Embeddings
  def self.provider
    StubbedEmbedding::StubProvider.new
  end
end

class ActiveSupport::TestCase
  parallelize(workers: 1)

  def auth_headers(token: ENV.fetch("AUTH_TOKEN"))
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  def perform_enqueued_jobs_now
    queue = ActiveJob::Base.queue_adapter
    return unless queue.respond_to?(:enqueued_jobs)
    while (job = queue.enqueued_jobs.shift)
      job[:job].new(*job[:args]).perform_now
    end
  end
end

ActiveJob::Base.queue_adapter = :test
