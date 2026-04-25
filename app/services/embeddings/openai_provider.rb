module Embeddings
  # OpenAI text-embedding-3-large with configurable output dimension.
  # Supports dimensions in [256, 3072]; we default to the deployment's
  # EMBEDDING_DIMENSION (1024 by default).
  #
  # Required env: OPENAI_API_KEY
  # Optional env: OPENAI_EMBEDDING_MODEL (default: text-embedding-3-large)
  class OpenaiProvider < Base
    ENDPOINT = "https://api.openai.com/v1/embeddings"

    def initialize
      @api_key = ENV.fetch("OPENAI_API_KEY")
      @model = ENV.fetch("OPENAI_EMBEDDING_MODEL", "text-embedding-3-large")
    end

    def embed(text)
      embed_batch([text]).first
    end

    def embed_batch(texts)
      response = http.post(
        ENDPOINT,
        {
          model: @model,
          input: texts,
          dimensions: self.class.dimension,
          encoding_format: "float"
        },
        {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => "application/json"
        }
      )

      raise EmbeddingError, "OpenAI #{response.status}: #{response.body}" unless response.success?

      response.body.fetch("data").map { |row| row.fetch("embedding") }
    end
  end
end
