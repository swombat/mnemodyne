module Embeddings
  # Google Gemini gemini-embedding-001 with configurable output dimensionality.
  # Supports up to 3072; we use the deployment's EMBEDDING_DIMENSION (1024 default).
  #
  # Required env: GEMINI_API_KEY
  # Optional env: GEMINI_EMBEDDING_MODEL (default: gemini-embedding-001)
  class GeminiProvider < Base
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def initialize
      @api_key = ENV.fetch("GEMINI_API_KEY")
      @model = ENV.fetch("GEMINI_EMBEDDING_MODEL", "gemini-embedding-001")
    end

    def embed(text)
      response = http.post(
        "#{BASE_URL}/models/#{@model}:embedContent?key=#{@api_key}",
        {
          model: "models/#{@model}",
          content: { parts: [{ text: text }] },
          outputDimensionality: self.class.dimension
        },
        { "Content-Type" => "application/json" }
      )

      raise EmbeddingError, "Gemini #{response.status}: #{response.body}" unless response.success?

      response.body.dig("embedding", "values")
    end
  end
end
