class AddSourceUrisToNodes < ActiveRecord::Migration[8.1]
  def change
    add_column :nodes, :source_uris, :text, array: true, default: [], null: false
    add_index  :nodes, :source_uris, using: :gin
  end
end
