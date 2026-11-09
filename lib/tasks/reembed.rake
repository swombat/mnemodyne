# Re-embed every node with the current provider/model, in batches, without
# touching updated_at. Used when VOYAGE_EMBEDDING_MODEL changes (same
# dimension). Back up first: create table nodes_embedding_backup_<date> as
# select id, embedding from nodes.
namespace :mnemodyne do
  task reembed: :environment do
    provider = Embeddings.provider
    done = 0
    Node.where.not(content: [nil, ""]).find_in_batches(batch_size: 100) do |batch|
      texts = batch.map(&:embedding_text)
      vectors = provider.embed_batch(texts)
      raise "count mismatch" unless vectors.size == batch.size
      batch.zip(vectors).each do |node, v|
        raise "dim #{v.size}" unless v.size == Embeddings.dimension
        node.update_columns(embedding: v)
      end
      done += batch.size
      puts "reembedded #{done}"
    end
  end
end
