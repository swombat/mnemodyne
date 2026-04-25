module Embeddings
  # Base class for embedding providers. Subclasses implement #embed.
  #
  # Providers are configured via environment variables and selected by
  # EMBEDDING_PROVIDER. The same provider must be used across the lifetime
  # of a deployment — vectors from different models live in different
  # mathematical spaces and cannot be compared meaningfully.
  class Base
    class EmbeddingError < StandardError; end

    DEFAULT_DIMENSION = 1024

    def self.dimension
      ENV.fetch("EMBEDDING_DIMENSION", DEFAULT_DIMENSION).to_i
    end

    # Returns an Array<Float> of length self.class.dimension.
    def embed(text)
      raise NotImplementedError, "#{self.class} must implement #embed"
    end

    # Batch interface; default implementation calls #embed in sequence.
    # Subclasses can override if the provider supports batching natively.
    def embed_batch(texts)
      texts.map { |t| embed(t) }
    end

    protected

    def http
      @http ||= Faraday.new do |f|
        f.request  :json
        f.response :json
        f.request  :retry,
                   max: 3,
                   interval: 0.5,
                   backoff_factor: 2,
                   retry_statuses: [429, 500, 502, 503, 504]
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end
  end
end
