require "test_helper"

# 2026-11-05 (souls.house YzmqKJ): a query equal to a memory's own content must
# return that memory first, even when a constitutional node (high charge, wired
# to a baseline-activated need) would win on final_score. Gravity may order the
# rest; it must not displace the match.
class RecallAnchorTest < ActiveSupport::TestCase
  setup do
    @need = Node.create!(node_type: "need", content: "to-have-a-sense-of-self", charge: 0.9,
                         metadata: { "baseline_activation" => 1.0 })
    @heavy = Array.new(6) do |i|
      mem("constitutional memory number #{i} about who I am", charge: 0.95).tap do |m|
        Edge.create!(source: m, target: @need, edge_type: "relates_to_need", weight: 1.0)
      end
    end
    @filler = Array.new(30) { |i| mem("ordinary filler memory #{i} with nothing in it", charge: 0.4) }
    @target = mem("the paperclip Daniel left on the Barcelona windowsill", charge: 0.1)
    Edge.create!(source: @target, target: @filler.first, edge_type: "theme", weight: 0.5)
    Node.find_each { |n| n.update_columns(embedding: Embeddings.provider.embed(n.embedding_text)) }
  end

  test "distance spread anchors on the exact match, not on gravity" do
    r = Recall.new(query: @target.content, reinforce: false, spread: "distance").call
    assert_equal @target.id, r[:results].first[:id]
    assert_equal 0, r[:results].first[:distance]
  end

  test "score spread returns the exact match first on every call" do
    20.times do
      r = Recall.new(query: @target.content, reinforce: false, spread: "score").call
      assert_equal @target.id, r[:results].first[:id]
      assert_equal 1, r[:results].count { |row| row[:id] == @target.id }
      assert_operator r[:results].length, :<=, Recall::DEFAULTS[:walk_count]
    end
  end

  test "an excluded exact match is not resurrected as the anchor" do
    r = Recall.new(query: @target.content, reinforce: false, spread: "score",
                   exclude_node_ids: [ @target.id ]).call
    refute_includes r[:results].map { |row| row[:id] }, @target.id
  end

  test "without a query, seed ids keep gravity's choice of anchor" do
    r = Recall.new(seed_node_ids: [ @target.id, @heavy.first.id ], reinforce: false, spread: "distance").call
    assert_equal @heavy.first.id, r[:results].first[:id]
  end

  private

  def mem(content, charge:)
    Node.create!(node_type: "memory", content: content, charge: charge)
  end
end
