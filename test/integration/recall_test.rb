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

  test "recall applies public rerank weight overrides" do
    body = {
      query: "anything",
      node_activations: {},
      reinforce: false,
      rerank_alpha_vector: 0.0,
      rerank_beta_alignment: 0.0,
      rerank_gamma_charge: 1.0
    }

    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert_operator json["results"].length, :>, 0
    json["results"].each do |result|
      assert_in_delta result["charge"], result["final_score"], 0.0001,
                      "expected charge-only scoring for node #{result["id"]}"
    end
  end

  test "string-valued numeric params are coerced, not crashed on" do
    body = {
      query: "anything",
      node_activations: {},
      reinforce: false,
      walk_depth: "3",
      rerank_alpha_vector: "0.0",
      rerank_beta_alignment: "0.0",
      rerank_gamma_charge: "1.0"
    }

    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert_operator json["results"].length, :>, 0
    json["results"].each do |result|
      assert_in_delta result["charge"], result["final_score"], 0.0001,
                      "string weights should coerce to charge-only scoring for node #{result["id"]}"
    end
  end

  test "garbage numeric params fall back to defaults instead of 500ing or zeroing weights" do
    body = {
      query: "anything",
      node_activations: {},
      reinforce: false,
      walk_depth: "banana",
      rerank_alpha_vector: "not-a-number",
      rerank_gamma_charge: [1.0]
    }

    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_operator json["results"].length, :>, 0

    # Defaults applied (alpha 0.4 / beta 0.3 / gamma 0.3), NOT alpha silently
    # zeroed by "not-a-number".to_f — under defaults final_score blends vector
    # similarity and alignment, so it should not collapse to charge alone for
    # every result.
    collapsed = json["results"].all? { |r| (r["final_score"] - r["charge"]).abs < 0.0001 }
    refute collapsed, "garbage weights must fall back to blended default scoring"
  end

  test "out-of-domain numeric params fall back to defaults" do
    body = {
      query: "being seen",
      seed_node_ids: [@joy.id],
      node_activations: { @being_met.id => 0.9 },
      reinforce: true,
      walk_depth: 0,
      walk_count: 0,
      base_reinforcement: "-1.0"
    }

    charge_before = @joy.reload.charge
    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert_operator json["results"].length, :>, 0,
                    "invalid walk_count should fall back to the documented default"
    assert_operator @joy.reload.charge, :>=, charge_before,
                    "invalid negative reinforcement must never lower stored charge"
    assert_includes 0.0..1.0, @joy.charge
  end

  test "negative vector seed pool falls back to the default" do
    body = {
      query: "anything",
      node_activations: {},
      reinforce: false,
      vector_seed_pool: -1
    }

    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok

    json = JSON.parse(response.body)
    assert_operator json["results"].length, :>, 0,
                    "invalid vector_seed_pool should not reach PostgreSQL as a negative LIMIT"
  end

  test "reinforcement never applies a negative delta" do
    charge_before = @joy.reload.charge
    result = Recall.new(
      query: "being seen",
      seed_node_ids: [@joy.id],
      node_activations: { @being_met.id => 1.0 },
      walk_depth: 0,
      walk_count: 1,
      reinforce: true,
      base_reinforcement: -1.0
    ).call

    assert_nil result[:results].first[:applied_reinforcement]
    assert_equal charge_before, @joy.reload.charge
    assert_includes 0.0..1.0, @joy.charge
  end

  test "string 'false' for reinforce is treated as false, not truthy" do
    body = {
      query: "being seen",
      node_activations: { @daniel.id => 0.85, @being_met.id => 0.9 },
      reinforce: "false"
    }

    charges_before = Node.pluck(:id, :charge).to_h
    post "/recall", params: body.to_json, headers: auth_headers
    assert_response :ok
    json = JSON.parse(response.body)

    json["results"].each do |result|
      assert_nil result["applied_reinforcement"],
                 "reinforce: \"false\" must not reinforce node #{result["id"]}"
    end
    assert_equal charges_before, Node.pluck(:id, :charge).to_h,
                 "no node charge may change when reinforce is the string \"false\""
  end

  test "charged recall reinforces aligned nodes more than unaligned ones" do
    body = {
      query: "being seen",
      node_activations: { @daniel.id => 0.85, @being_met.id => 0.9 },
      seed_node_ids: [@joy.id, @barrios.id],
      walk_depth: 0,
      walk_count: 2,
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
