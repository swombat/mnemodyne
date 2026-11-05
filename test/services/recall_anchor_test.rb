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

  test "a node whose text is the query is the anchor even when another vector is closer" do
    exact = mem("The  Kettle on the table", charge: 0.05)
    exact.update_columns(embedding: Embeddings.provider.embed("far away text"))
    %w[distance score].each do |spread|
      r = Recall.new(query: "the kettle on the TABLE ", reinforce: false, spread: spread).call
      assert_equal exact.id, r[:results].first[:id], spread
    end
  end

  test "identical-text duplicates resolve to the closer vector, deterministically" do
    q = "duplicate memory text"
    near = mem(q, charge: 0.1)
    far  = mem("Duplicate  memory text", charge: 0.9)
    near.update_columns(embedding: Embeddings.provider.embed(q))
    far.update_columns(embedding: Embeddings.provider.embed("unrelated"))
    5.times do
      assert_equal near.id, Recall.new(query: q, reinforce: false, spread: "distance").call[:results].first[:id]
    end
  end

  test "a lexically reserved node is still walked through in distance spread" do
    a = mem("chain start about teapots", charge: 0.5)
    b = mem("the Zorblax link in the middle", charge: 0.5)
    c = mem("final node two hops out", charge: 0.5)
    Edge.create!(source: a, target: b, edge_type: "theme", weight: 0.9)
    Edge.create!(source: b, target: c, edge_type: "theme", weight: 0.9)
    [ a, b, c ].each { |n| n.update_columns(embedding: Embeddings.provider.embed(n.embedding_text)) }
    r = Recall.new(query: "chain start about teapots Zorblax", seed_node_ids: [ a.id ], reinforce: false, spread: "distance").call
    by_id = r[:results].to_h { |row| [ row[:id], row[:distance] ] }
    assert_equal 0, by_id[a.id]
    assert by_id.key?(b.id), "lexical reservation returned"
    assert_equal 2, by_id[c.id], "path through the reserved node survives"
  end

  test "a short query counts a three-letter name" do
    ada = mem("Lunch with Ada on Thursday", charge: 0.01)
    ada.update_columns(embedding: Embeddings.provider.embed("nothing like it"))
    ids = Recall.new(query: "Ada", reinforce: false, spread: "score").call[:results].map { |r| r[:id] }
    assert_includes ids, ada.id
    long = Recall.new(query: "tell me ada stuff from the past year or so", reinforce: false)
    refute_includes long.send(:lexical_matches).map(&:id), ada.id
  end

  test "exact-text matching normalises both sides the same way in PostgreSQL" do
    literal = mem("Ｑｕｉｌｌａｎ  at the door", charge: 0.1)
    ascii   = mem("quillan at the door", charge: 0.1)
    literal.update_columns(embedding: Embeddings.provider.embed("Ｑｕｉｌｌａｎ at the door"))
    ascii.update_columns(embedding: Embeddings.provider.embed("something else"))
    r = Recall.new(query: "Ｑｕｉｌｌａｎ at the door", reinforce: false, spread: "distance").call
    assert_equal literal.id, r[:results].first[:id], "both are exact after NFKC; the closer vector wins"
    r = Recall.new(query: "\tquillan   AT the door \n", reinforce: false, spread: "distance").call
    assert_includes [ literal.id, ascii.id ], r[:results].first[:id]
  end

  private

  def mem(content, charge:)
    Node.create!(node_type: "memory", content: content, charge: charge)
  end
end
