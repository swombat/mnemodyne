require "test_helper"

class EdgeTest < ActiveSupport::TestCase
  setup do
    @a = Node.create!(node_type: "memory", content: "a")
    @b = Node.create!(node_type: "memory", content: "b")
  end

  test "valid edge" do
    e = Edge.new(source: @a, target: @b, edge_type: "theme", weight: 0.5)
    assert e.valid?
  end

  test "rejects self-loop" do
    e = Edge.new(source: @a, target: @a, edge_type: "theme", weight: 0.5)
    refute e.valid?
    assert_includes e.errors[:target_id].join, "no self-loops"
  end

  test "rejects out-of-range weight" do
    refute Edge.new(source: @a, target: @b, edge_type: "x", weight: 1.5).valid?
    refute Edge.new(source: @a, target: @b, edge_type: "x", weight: -0.1).valid?
  end

  test "uniqueness on (source, target, edge_type) at the DB level" do
    Edge.create!(source: @a, target: @b, edge_type: "theme")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Edge.create!(source: @a, target: @b, edge_type: "theme")
    end
  end
end
