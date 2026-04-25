class CreateNodes < ActiveRecord::Migration[8.1]
  EMBEDDING_DIMENSION = ENV.fetch("EMBEDDING_DIMENSION", "1024").to_i

  def change
    create_table :nodes, id: :uuid do |t|
      # Named "node_type" rather than "type" to avoid Active Record STI magic.
      # Values are semantic ("memory", "need", "person", ...), not class names.
      t.string  :node_type, null: false
      t.text    :content, null: false
      t.text    :description
      t.float   :charge, null: false, default: 0.5
      t.string  :integration_state, null: false, default: "raw"
      t.datetime :state_changed_at
      t.boolean :is_dormant, null: false, default: false
      t.jsonb   :metadata, null: false, default: {}
      t.vector  :embedding, limit: EMBEDDING_DIMENSION
      t.timestamps
    end

    add_index :nodes, :node_type
    add_index :nodes, :integration_state
    add_index :nodes, :is_dormant
    add_index :nodes, :charge
    add_index :nodes, :metadata, using: :gin

    # Lookup-by-name uniqueness for nodes that have natural names (needs, persons).
    # Memory nodes (which can repeat content) are excluded by the WHERE clause.
    add_index :nodes,
              [:node_type, :content],
              unique: true,
              where: "node_type IN ('need', 'person')",
              name: "index_nodes_on_node_type_and_content_for_named_types"

    # IVFFlat index for cosine-distance similarity search on embeddings.
    # Created with default lists; revisit when corpus exceeds ~10k nodes.
    execute <<~SQL
      CREATE INDEX index_nodes_on_embedding_cosine
      ON nodes USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100)
    SQL
  end
end
