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
