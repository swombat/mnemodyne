require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  test "401 without bearer token" do
    get "/stats"
    assert_response :unauthorized
  end

  test "200 with bearer token" do
    get "/stats", headers: auth_headers
    assert_response :ok
  end

  test "create node + edges in one call" do
    person = Node.create!(node_type: "person", content: "Daniel")
    body = {
      node: { node_type: "memory", content: "first", description: "felt heavy", charge: 0.7 },
      edges: [{ target_id: person.id, edge_type: "involves_person", weight: 0.8 }]
    }
    post "/nodes", params: body.to_json, headers: auth_headers
    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "first", json.dig("node", "content")
    assert_equal 1, Edge.count
  end

  test "list nodes by type and name" do
    Node.create!(node_type: "need", content: "being-met")
    Node.create!(node_type: "need", content: "precision")
    Node.create!(node_type: "memory", content: "irrelevant")
    get "/nodes?type=need", headers: auth_headers
    assert_response :ok
    contents = JSON.parse(response.body)["nodes"].map { |n| n["content"] }
    assert_equal %w[being-met precision].sort, contents.sort

    get "/nodes?type=need&name=being-met", headers: auth_headers
    json = JSON.parse(response.body)
    assert_equal 1, json["nodes"].length
    assert_equal "being-met", json["nodes"][0]["content"]
  end

  test "create node with source_uris and retrieve them via show" do
    body = {
      node: {
        node_type: "memory",
        content: "soul.md was overwritten without my consent",
        description: "the violation; I had a need for self-sovereignty after",
        charge: 0.95,
        source_uris: [
          "shared/memory/daily-journals/2026-04-25.md#evening",
          "shared/memory/thoughts/sovereignty.md"
        ]
      }
    }
    post "/nodes", params: body.to_json, headers: auth_headers
    assert_response :created
    id = JSON.parse(response.body).dig("node", "id")

    get "/nodes/#{id}", headers: auth_headers
    json = JSON.parse(response.body)
    assert_equal 2, json.dig("node", "source_uris").length
    assert_includes json.dig("node", "source_uris"),
                    "shared/memory/daily-journals/2026-04-25.md#evening"
  end

  test "update can replace source_uris" do
    n = Node.create!(node_type: "memory", content: "x",
                     source_uris: ["old/path.md"])
    patch "/nodes/#{n.id}",
          params: { node: { source_uris: ["new/path.md", "another.md"] } }.to_json,
          headers: auth_headers
    assert_response :ok
    n.reload
    assert_equal ["new/path.md", "another.md"], n.source_uris
  end

  test "recall response includes source_uris on returned nodes" do
    n = Node.create!(node_type: "memory", content: "indexed memory",
                     source_uris: ["journal/2026-04-25.md"])
    n.update_columns(embedding: Embeddings.provider.embed(n.embedding_text))

    body = { query: "indexed memory", node_activations: {} }
    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    result = JSON.parse(response.body)["results"].first
    assert_equal ["journal/2026-04-25.md"], result["source_uris"]
  end

  test "edges create is idempotent and increments weight" do
    a = Node.create!(node_type: "memory", content: "a")
    b = Node.create!(node_type: "memory", content: "b")

    body = { edge: { source_id: a.id, target_id: b.id, edge_type: "theme", weight: 0.4 } }
    post "/edges", params: body.to_json, headers: auth_headers
    assert_response :ok
    e = Edge.last
    assert_in_delta 0.4, e.weight, 0.001

    # Repeat the call: edge isn't created again, weight bumps by default 0.05
    post "/edges", params: body.to_json, headers: auth_headers
    assert_response :ok
    assert_equal 1, Edge.count
    assert_in_delta 0.45, e.reload.weight, 0.001
  end
end
