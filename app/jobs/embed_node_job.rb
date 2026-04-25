class EmbedNodeJob < ApplicationJob
  queue_as :default

  retry_on Embeddings::Base::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::TimeoutError,            wait: :polynomially_longer, attempts: 5
  retry_on Faraday::ConnectionFailed,        wait: :polynomially_longer, attempts: 5

  def perform(node_id)
    node = Node.find_by(id: node_id)
    return unless node

    text = node.embedding_text
    return if text.blank?

    vector = Embeddings.provider.embed(text)

    if vector.length != Embeddings.dimension
      raise Embeddings::Base::EmbeddingError,
            "Provider returned #{vector.length}-dim vector; expected #{Embeddings.dimension}"
    end

    node.update_columns(embedding: vector, updated_at: Time.current)
  end
end
