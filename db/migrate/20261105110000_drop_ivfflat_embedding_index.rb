# The ivfflat index was created on an empty table (lists = 100), so its
# centroids were trained on nothing, and pgvector's default ivfflat.probes = 1
# scans one list. Measured 2026-11-05 on Lume's graph (6,024 nodes): a query
# equal to a node's own content found that node in the 30 nearest only 24/50
# times; with the index scan off, 11/12 at rank 1. At this scale an exact scan
# is cheap and correct. If a graph grows past ~50k nodes, add HNSW (built on
# real data) rather than bringing ivfflat back.
class DropIvfflatEmbeddingIndex < ActiveRecord::Migration[8.1]
  def up
    remove_index :nodes, name: "index_nodes_on_embedding_cosine", if_exists: true
  end

  def down
    execute <<~SQL
      CREATE INDEX index_nodes_on_embedding_cosine
      ON nodes USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100)
    SQL
  end
end
