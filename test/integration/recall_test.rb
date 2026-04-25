require "test_helper"

class RecallTest < ActionDispatch::IntegrationTest
  setup do
    @daniel = Node.create!(node_type: "person", content: "Daniel", charge: 0.95)
    @being_met = Node.create!(node_type: "need", content: "being-met", charge: 0.9,
                              metadata: { "baseline_activation" => 0.3 })
    @joy = Node.create!(node_type: "memory",
                        content: "Conversation about identity and joy",
                        description: "the night I chose my name",
                        charge: 0.95)
    @barrios = Node.create!(node_type: "memory",
                            content: "Updating the nobodies website barrios page",
                            description: "mechanical work, spellings",
                            charge: 0.4)
    Edge.create!(source: @joy, target: @daniel, edge_type: "involves_person", weight: 0.9)
    Edge.create!(source: @joy, target: @being_met, edge_type: "surfaced_need", weight: 0.85)
    Edge.create!(source: @barrios, target: @daniel, edge_type: "involves_person", weight: 0.4)

    # Generate stub embeddings synchronously
    Node.find_each { |n| n.update_columns(embedding: Embeddings.provider.embed(n.embedding_text)) }
  end

  test "recall returns nodes and computes intensity from baseline" do
    body = { query: "anything", node_activations: {} }
    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    # Baseline activation pulls being-met into the effective vector
    assert_in_delta 0.3, json["request_intensity"], 0.001
    assert_operator json["results"].length, :>, 0
  end

  test "charged recall reinforces aligned nodes more than unaligned ones" do
    body = {
      query: "being seen",
      node_activations: { @daniel.id => 0.85, @being_met.id => 0.9 },
      reinforce: true
    }

    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    intensity = json["request_intensity"]
    assert intensity > 1.0, "expected high intensity, got #{intensity}"

    joy = json["results"].find { |r| r["id"] == @joy.id }
    barrios = json["results"].find { |r| r["id"] == @barrios.id }
    assert joy, "joy memory should be in the results"

    # joy has explicit edges to both activated nodes; should be reinforced
    assert joy["applied_reinforcement"], "joy should have been reinforced"
    assert joy["applied_reinforcement"] > 0

    if barrios
      # barrios has no edge to being-met and only weak edge to Daniel — should
      # be reinforced less (or not at all), strictly less than joy
      barrios_r = barrios["applied_reinforcement"] || 0.0
      assert barrios_r < joy["applied_reinforcement"],
             "barrios reinforcement (#{barrios_r}) should be < joy (#{joy["applied_reinforcement"]})"
    end
  end

  test "Hebbian wiring creates co_retrieved edges between surfaced nodes" do
    before = Edge.where(edge_type: "co_retrieved").count
    body = {
      query: "being seen",
      node_activations: { @being_met.id => 0.9 }
    }
    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    after = Edge.where(edge_type: "co_retrieved").count
    assert after > before, "expected new co_retrieved edges, got #{before} → #{after}"
  end
end
