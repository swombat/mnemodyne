module Embeddings
  # Voyage AI voyage-3 (Anthropic's recommended embedding partner). Native
  # 1024-dim. Supports input_type=document|query for asymmetric retrieval.
  #
  # Required env: VOYAGE_API_KEY
  # Optional env: VOYAGE_EMBEDDING_MODEL (default: voyage-3)
  class VoyageProvider < Base
    ENDPOINT = "https://api.voyageai.com/v1/embeddings"

    def initialize
      @api_key = ENV.fetch("VOYAGE_API_KEY")
      @model = ENV.fetch("VOYAGE_EMBEDDING_MODEL", "voyage-3")
    end

    def embed(text, input_type: "document")
      embed_batch([text], input_type: input_type).first
    end

    def embed_batch(texts, input_type: "document")
      response = http.post(
        ENDPOINT,
        {
          model: @model,
          input: texts,
          input_type: input_type
        },
        {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => "application/json"
        }
      )

      raise EmbeddingError, "Voyage #{response.status}: #{response.body}" unless response.success?

      response.body.fetch("data").map { |row| row.fetch("embedding") }
    end
  end
end
