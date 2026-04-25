module Embeddings
  PROVIDERS = {
    "openai" => "Embeddings::OpenaiProvider",
    "gemini" => "Embeddings::GeminiProvider",
    "voyage" => "Embeddings::VoyageProvider",
    "local"  => "Embeddings::LocalProvider"
  }.freeze

  def self.provider
    name = ENV.fetch("EMBEDDING_PROVIDER", "openai").downcase
    klass_name = PROVIDERS[name] || raise(
      Embeddings::Base::EmbeddingError,
      "Unknown EMBEDDING_PROVIDER=#{name}. Valid: #{PROVIDERS.keys.join(', ')}"
    )
    klass_name.constantize.new
  end

  def self.dimension
    Base.dimension
  end
end
