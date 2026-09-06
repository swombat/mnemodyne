require "test_helper"

class DreamingTest < ActionDispatch::IntegrationTest
  # Sampler owns a repeatable-read snapshot. Test DB only; all embeddings stubbed.
  self.use_transactional_tests = false
  setup { Edge.delete_all; Node.delete_all }
  teardown { Edge.delete_all; Node.delete_all }

  def memory(**attrs)
    Node.create!({ node_type: "memory", content: "fragment" }.merge(attrs))
  end

  def sample(**params)
    get "/nodes/sample", params: params, headers: auth_headers
    assert_response :ok
    JSON.parse(response.body)
  end

  test "sample is authenticated including empty pool" do
    get "/nodes/sample"
    assert_response :unauthorized
    assert_empty sample["nodes"]
  end

  test "all memories including dormant but never hubs dreams exempt or private material" do
    active = memory(description: "NEVER SEND WHY", source_uris: ["journal/a"])
    dormant = memory(is_dormant: true, charge: 0.01, metadata: { dream_exempt: false })
    memory(metadata: { dream_exempt: true })
    person = Node.create!(node_type: "person", content: "private", is_dormant: true,
                          metadata: { privacy_level: "high" })
    Node.create!(node_type: "need", content: "need")
    Node.create!(node_type: "dream", content: "Dream — fiction")
    [true, false].each do |reverse|
      m = memory
      Edge.create!(source: reverse ? person : m, target: reverse ? m : person,
                   edge_type: "involves_person")
    end
    before = Node.order(:id).pluck(:id, :charge, :is_dormant, :updated_at)
    edge_count = Edge.count
    json = sample(n: 100, seed: 1, include_dormant: true)
    assert_equal [active.id, dormant.id].sort, json["nodes"].map { |n| n["id"] }.sort
    assert_equal 2, json["eligible_count"]
    assert_equal %w[content id is_dormant node_type source_uris], json["nodes"].first.keys.sort
    assert_equal before, Node.order(:id).pluck(:id, :charge, :is_dormant, :updated_at)
    assert_equal edge_count, Edge.count
    assert_equal [active.id], sample(include_dormant: false)["nodes"].map { |n| n["id"] }
  end

  test "ordinary person links and other edge types are not exclusions" do
    m = memory
    private_person = Node.create!(node_type: "person", content: "private", metadata: { privacy_level: "high" })
    ordinary = Node.create!(node_type: "person", content: "ordinary")
    Edge.create!(source: m, target: ordinary, edge_type: "involves_person")
    Edge.create!(source: m, target: private_person, edge_type: "theme")
    assert_equal [m.id], sample["nodes"].map { |n| n["id"] }
  end

  test "seeded sample is repeatable unique and spans the full pool" do
    15.times { |i| memory(content: "fragment #{i}", charge: i / 20.0, is_dormant: i.odd?) }
    first = sample(n: 5, seed: 123)
    assert_equal first, sample(n: 5, seed: 123)
    assert_equal 5, first["nodes"].map { |n| n["id"] }.uniq.length
    seen = (1..20).flat_map { |seed| sample(n: 5, seed: seed)["nodes"].map { |n| n["id"] } }.uniq
    assert_equal 15, seen.length
  end

  test "sampling validates bounds and booleans without silent coercion" do
    [{ n: 0 }, { n: 501 }, { n: "1.2" }, { n: [] }, { seed: -1 },
     { seed: 2**63 }, { include_dormant: "maybe" }].each do |params|
      get "/nodes/sample", params: params, headers: auth_headers
      assert_response :bad_request
    end
  end

  test "reinforcement is per node clamped and dormancy is an explicit choice" do
    chosen = memory(charge: 0.99, is_dormant: true)
    untouched = memory(charge: 0.2)
    post "/nodes/#{chosen.id}/reinforce", params: {}.to_json, headers: auth_headers
    assert_response :ok
    assert_equal 1.0, chosen.reload.charge
    assert chosen.is_dormant
    assert_equal 0.2, untouched.reload.charge
    assert_equal 0, Edge.count
    post "/nodes/#{chosen.id}/reinforce", params: { reactivate: true }.to_json, headers: auth_headers
    assert_response :ok
    assert_not chosen.reload.is_dormant
  end

  test "reinforce rejects bad boolean and requires authentication" do
    n = memory(charge: 0.5, is_dormant: true)
    post "/nodes/#{n.id}/reinforce", params: { reactivate: "yes" }.to_json, headers: auth_headers
    assert_response :bad_request
    assert_equal 0.5, n.reload.charge
    assert n.is_dormant
    post "/nodes/#{n.id}/reinforce"
    assert_response :unauthorized
    post "/nodes/#{n.id}/reinforce", params: { reactivate: false }.to_json, headers: auth_headers
    assert_response :ok
    assert_in_delta 0.52, n.reload.charge
    assert n.is_dormant
  end

  test "kept dream is an ordinary recallable node without automatic source edges" do
    post "/nodes", params: { node: { node_type: "dream", content: "Dream — invented room",
      source_uris: ["memory/dreams/test.md"], metadata: { fiction: true, sampled: [memory.id] } } }.to_json,
      headers: auth_headers
    assert_response :created
    id = JSON.parse(response.body).dig("node", "id")
    node = Node.find(id)
    node.update_columns(embedding: Embeddings.provider.embed(node.embedding_text))
    assert_equal 0, Edge.count
    post "/recall", params: { seed_node_ids: [id], node_type_filter: ["memory", "dream"],
      spread: "distance", reinforce: false }.to_json, headers: auth_headers
    assert_response :ok
    result = JSON.parse(response.body)["results"].find { |r| r["id"] == id }
    assert_equal "dream", result["node_type"]
    assert_equal ["memory/dreams/test.md"], result["source_uris"]
    assert_equal 0, Edge.count
  end
end
