require "test_helper"

# Distance spread (2026-09-06). Graph under test, authored edges only unless noted:
#
#   anchor ──theme──▶ near            (distance 1: explicitly linked memory)
#   anchor ──relates_to_need──▶ need ◀──relates_to_need── viaNeed   (distance 2: shares a hub)
#   viaNeed ──involves_person──▶ person ◀──involves_person── far     (distance 4: via two hubs)
#   anchor ──co_retrieved──▶ hebbian   (must NOT count as distance 1)
#   anchor ──theme──▶ dormant          (dormant: neither traversed nor returned)
#   lonely                             (no edges; only reachable as a vector seed)
class RecallSpreadTest < ActiveSupport::TestCase
  setup do
    @anchor  = mem("anchor memory about the kettle on the table", charge: 0.6)
    @near    = mem("near memory, the same kettle", charge: 0.5)
    @via     = mem("memory sharing the need", charge: 0.5)
    @far     = mem("memory two hubs away", charge: 0.5)
    @hebbian = mem("co-retrieved neighbour", charge: 0.9)
    @dormant = mem("dormant memory", charge: 0.9, is_dormant: true)
    @lonely  = mem("unconnected memory", charge: 0.5)
    @need    = Node.create!(node_type: "need", content: "to-notice-the-kettle", charge: 0.5,
                            metadata: { "baseline_activation" => 0.5 })
    @person  = Node.create!(node_type: "person", content: "Somebody", charge: 0.5)

    Edge.create!(source: @anchor, target: @near,    edge_type: "theme",           weight: 0.8)
    Edge.create!(source: @anchor, target: @need,    edge_type: "relates_to_need", weight: 0.8)
    Edge.create!(source: @via,    target: @need,    edge_type: "relates_to_need", weight: 0.8)
    Edge.create!(source: @via,    target: @person,  edge_type: "involves_person", weight: 0.8)
    Edge.create!(source: @far,    target: @person,  edge_type: "involves_person", weight: 0.8)
    Edge.create!(source: @anchor, target: @hebbian, edge_type: "co_retrieved",    weight: 1.0)
    Edge.create!(source: @anchor, target: @dormant, edge_type: "theme",           weight: 1.0)

    # Embed synchronously so vector seeding works with the stub provider.
    Node.find_each { |n| n.update_columns(embedding: Embeddings.provider.embed(n.embedding_text)) }
  end

  test "anchor is the top-scored seed and is always returned at distance 0" do
    r = recall(seed_node_ids: [ @anchor.id, @lonely.id ])
    assert_equal "distance", r[:spread]
    assert_equal 0, r[:results].first[:distance]
    assert_includes [ @anchor.id, @lonely.id ], r[:results].first[:id]
  end

  test "layers follow authored edges through hubs and never count co_retrieved" do
    r = recall(seed_node_ids: [ @anchor.id ], walk_count: 5)
    by_id = r[:results].to_h { |row| [ row[:id], row[:distance] ] }
    assert_equal 0, by_id[@anchor.id]
    assert_equal 1, by_id[@near.id],  "explicitly linked memory is one hop"
    assert_equal 2, by_id[@via.id],   "sharing a need is two hops"
    assert_equal 4, by_id[@far.id],   "two hubs away is four hops"
    assert_nil by_id[@hebbian.id],    "co_retrieved must not create distance"
    assert_nil by_id[@need.id],       "hubs are traversed, not returned"
    assert_nil by_id[@person.id]
    assert_nil by_id[@dormant.id]
  end

  test "a sparse graph returns fewer results rather than padding a layer" do
    r = recall(seed_node_ids: [ @lonely.id ], walk_count: 5)
    assert_equal 1, r[:results].length
    assert_equal @lonely.id, r[:results].first[:id]
  end

  test "excluded ids are skipped within layers and the ladder continues past them" do
    r = recall(seed_node_ids: [ @anchor.id ], walk_count: 3, exclude_node_ids: [ @near.id ])
    by_id = r[:results].to_h { |row| [ row[:id], row[:distance] ] }
    assert_equal 0, by_id[@anchor.id]
    assert_nil by_id[@near.id], "session-seen node is skipped"
    assert_equal 2, by_id[@via.id], "the layer is skipped, not the ladder"
  end

  test "when every seed is already seen there is no anchor and nothing is returned" do
    r = recall(seed_node_ids: [ @anchor.id, @near.id ], exclude_node_ids: [ @anchor.id, @near.id ])
    assert_empty r[:results]
  end

  test "each returned memory is the best-scored in its layer" do
    strong = mem("another near memory", charge: 1.0)
    Edge.create!(source: @anchor, target: strong, edge_type: "theme", weight: 0.8)
    strong.update_columns(embedding: Embeddings.provider.embed(strong.embedding_text))
    r = recall(seed_node_ids: [ @anchor.id ], walk_count: 2)
    assert_equal strong.id, r[:results].last[:id], "charge 1.0 beats charge 0.5 at the same distance"
    assert_equal 1, r[:results].last[:distance]
  end

  test "score spread is unchanged by default and honours exclusions" do
    r = Recall.new(seed_node_ids: [ @anchor.id ], walk_count: 5, reinforce: false,
                   exclude_node_ids: [ @anchor.id ]).call
    assert_equal "score", r[:spread]
    assert_not_includes r[:results].map { |row| row[:id] }, @anchor.id
    assert r[:results].all? { |row| row[:distance].nil? }
  end

  test "unknown spread is rejected" do
    assert_raises(ArgumentError) { Recall.new(seed_node_ids: [ @anchor.id ], spread: "banana") }
  end

  private

  def mem(content, **attrs)
    Node.create!(node_type: "memory", content: content, **attrs)
  end

  def recall(**opts)
    Recall.new(spread: "distance", reinforce: false, **opts).call
  end
end
