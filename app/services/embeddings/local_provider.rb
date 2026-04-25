module Embeddings
  # Self-hosted sidecar provider. Posts to a local HTTP service that
  # wraps a sentence-transformers / fastembed / similar model.
  #
  # Sidecar contract:
  #   POST <base_url>/embed   { "texts": ["..."] }  →  { "vectors": [[...]] }
  #
  # A reference sidecar lives in `sidecar/embedder/` (Python + FastAPI +
  # sentence-transformers BAAI/bge-large-en-v1.5).
  #
  # Required env: EMBEDDING_SIDECAR_URL (e.g., http://embedder:8080)
  class LocalProvider < Base
    def initialize
      @base_url = ENV.fetch("EMBEDDING_SIDECAR_URL")
    end

    def embed(text)
      embed_batch([text]).first
    end

    def embed_batch(texts)
      response = http.post(
        "#{@base_url}/embed",
        { texts: texts },
        { "Content-Type" => "application/json" }
      )

      raise EmbeddingError, "Sidecar #{response.status}: #{response.body}" unless response.success?

      response.body.fetch("vectors")
    end
  end
end
