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

  test "an unembedded seed never wins the anchor on the 0.5 fallback" do
    bare = mem("unembedded seed", charge: 0.95)
    bare.update_columns(embedding: nil)
    %w[distance score].each do |spread|
      r = Recall.new(query: "an unrelated question", seed_node_ids: [ bare.id, @target.id ],
                     reinforce: false, spread: spread).call
      assert_equal @target.id, r[:results].first[:id], spread
    end
  end

  test "with only unembedded seeds the anchor falls back to gravity without failing" do
    bare = mem("unembedded seed", charge: 0.95)
    bare.update_columns(embedding: nil)
    %w[distance score].each do |spread|
      r = Recall.new(query: "an unrelated question", seed_node_ids: [ bare.id ], reinforce: false, spread: spread).call
      assert_equal bare.id, r[:results].first[:id], spread
    end
  end

  test "a rare proper noun returns the one memory that contains it, in both spreads" do
    needle = mem("Playa ate a Physarum culture off the windowsill", charge: 0.05)
    needle.update_columns(embedding: Embeddings.provider.embed("something unrelated entirely"))
    %w[distance score].each do |spread|
      ids = Recall.new(query: "what do I know about physarum", reinforce: false, spread: spread).call[:results].map { |r| r[:id] }
      assert_includes ids, needle.id, spread
    end
  end

  test "a term in more than lexical_max_df nodes does not reserve a slot" do
    4.times { |i| mem("filler mentioning Barcelona #{i}", charge: 0.01) }
    r = Recall.new(query: "Barcelona", reinforce: false, spread: "score").call
    assert_empty r[:results].select { |row| row[:match] == "lexical" }
  end

  test "lexical matches never return hubs or excluded nodes" do
    person = Node.create!(node_type: "person", content: "Quillon", charge: 0.5)
    hidden = mem("Quillon said something once", charge: 0.5)
    r = Recall.new(query: "Quillon", reinforce: false, spread: "distance", exclude_node_ids: [ hidden.id ]).call
    ids = r[:results].map { |row| row[:id] }
    refute_includes ids, person.id
    refute_includes ids, hidden.id
  end

  private

  def mem(content, charge:)
    Node.create!(node_type: "memory", content: content, charge: charge)
  end
end
