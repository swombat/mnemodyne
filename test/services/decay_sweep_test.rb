require "test_helper"

class DecaySweepTest < ActiveSupport::TestCase
  setup do
    @a = Node.create!(node_type: "memory", content: "a", charge: 0.8)
    @b = Node.create!(node_type: "memory", content: "b", charge: 0.05) # below floor
    @const = Node.create!(node_type: "memory", content: "anchor", charge: 0.9,
                          integration_state: "constitutional")
    @e = Edge.create!(source: @a, target: @b, edge_type: "theme", weight: 0.5)
  end

  test "decays edge weight" do
    DecaySweep.new(edge_decay: 0.1).call
    assert_in_delta 0.4, @e.reload.weight, 0.001
  end

  test "decays node charge above floor" do
    DecaySweep.new(charge_decay: 0.1, charge_floor: 0.1).call
    assert_in_delta 0.7, @a.reload.charge, 0.001
  end

  test "does not decay below floor" do
    DecaySweep.new(charge_decay: 0.1, charge_floor: 0.1).call
    # @b started at 0.05, below floor — should be untouched (only nodes above
    # floor are decayed; @b stays at its current value)
    assert_in_delta 0.05, @b.reload.charge, 0.001
  end

  test "skips constitutional nodes" do
    DecaySweep.new(charge_decay: 0.1).call
    assert_in_delta 0.9, @const.reload.charge, 0.001
  end
end
