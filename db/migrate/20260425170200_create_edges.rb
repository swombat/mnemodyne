class CreateEdges < ActiveRecord::Migration[8.1]
  def change
    create_table :edges, id: :uuid do |t|
      t.references :source, type: :uuid, null: false,
                   foreign_key: { to_table: :nodes, on_delete: :cascade }
      t.references :target, type: :uuid, null: false,
                   foreign_key: { to_table: :nodes, on_delete: :cascade }
      t.string  :edge_type, null: false
      t.float   :weight, null: false, default: 0.5
      t.jsonb   :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :edges, [:source_id, :target_id, :edge_type], unique: true,
              name: "index_edges_unique_triple"
    add_index :edges, :edge_type
    add_index :edges, :weight
  end
end
