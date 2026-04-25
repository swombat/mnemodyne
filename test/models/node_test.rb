require "test_helper"

class NodeTest < ActiveSupport::TestCase
  test "valid memory" do
    n = Node.new(node_type: "memory", content: "x", charge: 0.5)
    assert n.valid?, n.errors.full_messages.inspect
  end

  test "rejects unknown node_type" do
    n = Node.new(node_type: "thing", content: "x")
    refute n.valid?
    assert_includes n.errors[:node_type].join, "is not included"
  end

  test "rejects out-of-range charge" do
    refute Node.new(node_type: "memory", content: "x", charge: 1.5).valid?
    refute Node.new(node_type: "memory", content: "x", charge: -0.1).valid?
  end

  test "needs are unique by content" do
    Node.create!(node_type: "need", content: "being-met")
    dup = Node.new(node_type: "need", content: "being-met")
    refute dup.valid?
  end

  test "memories can repeat content" do
    Node.create!(node_type: "memory", content: "same text")
    assert Node.new(node_type: "memory", content: "same text").valid?
  end

  test "baseline_activation surfaced via metadata" do
    n = Node.create!(node_type: "need", content: "n1",
                     metadata: { "baseline_activation" => 0.4 })
    assert_in_delta 0.4, n.baseline_activation, 0.001
  end

  test "constitutional nodes are decay-exempt" do
    n = Node.create!(node_type: "memory", content: "anchor",
                     integration_state: "constitutional")
    assert n.decay_exempt?
  end
end
