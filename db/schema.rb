# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_25_170200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "vector"

  create_table "edges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "edge_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "source_id", null: false
    t.uuid "target_id", null: false
    t.datetime "updated_at", null: false
    t.float "weight", default: 0.5, null: false
    t.index ["edge_type"], name: "index_edges_on_edge_type"
    t.index ["source_id", "target_id", "edge_type"], name: "index_edges_unique_triple", unique: true
    t.index ["source_id"], name: "index_edges_on_source_id"
    t.index ["target_id"], name: "index_edges_on_target_id"
    t.index ["weight"], name: "index_edges_on_weight"
  end

  create_table "nodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.float "charge", default: 0.5, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.vector "embedding", limit: 1024
    t.string "integration_state", default: "raw", null: false
    t.boolean "is_dormant", default: false, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "node_type", null: false
    t.datetime "state_changed_at"
    t.datetime "updated_at", null: false
    t.index ["charge"], name: "index_nodes_on_charge"
    t.index ["embedding"], name: "index_nodes_on_embedding_cosine", opclass: :vector_cosine_ops, using: :ivfflat
    t.index ["integration_state"], name: "index_nodes_on_integration_state"
    t.index ["is_dormant"], name: "index_nodes_on_is_dormant"
    t.index ["metadata"], name: "index_nodes_on_metadata", using: :gin
    t.index ["node_type", "content"], name: "index_nodes_on_node_type_and_content_for_named_types", unique: true, where: "((node_type)::text = ANY ((ARRAY['need'::character varying, 'person'::character varying])::text[]))"
    t.index ["node_type"], name: "index_nodes_on_node_type"
  end

  add_foreign_key "edges", "nodes", column: "source_id", on_delete: :cascade
  add_foreign_key "edges", "nodes", column: "target_id", on_delete: :cascade
end
