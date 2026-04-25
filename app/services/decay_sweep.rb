# DecaySweep — the only autonomous behaviour the service performs.
#
# Runs nightly via Solid Queue's recurring tasks (config/recurring.yml). Reads
# rates from environment variables; the agent owns these values by editing the
# deployment env, not via API.
#
#   DECAY_RATE          — daily decrement on edge weights        (default 0.005)
#   CHARGE_DECAY_RATE   — daily decrement on node charge         (default 0.001)
#   CHARGE_DECAY_FLOOR  — charge does not decay below this floor (default 0.1)
#
# Constitutional nodes and metadata.decay_exempt nodes are skipped.
class DecaySweep
  def initialize(
    edge_decay:    ENV.fetch("DECAY_RATE",         "0.005").to_f,
    charge_decay:  ENV.fetch("CHARGE_DECAY_RATE",  "0.001").to_f,
    charge_floor:  ENV.fetch("CHARGE_DECAY_FLOOR", "0.1").to_f
  )
    @edge_decay   = edge_decay
    @charge_decay = charge_decay
    @charge_floor = charge_floor
  end

  def call
    started_at = Time.current

    edges_decayed = Edge.where("weight > 0").update_all(
      "weight = GREATEST(0, weight - #{@edge_decay.to_f})"
    )

    nodes_decayed = Node.where(
      "charge > :floor AND integration_state <> 'constitutional' " \
      "AND COALESCE((metadata->>'decay_exempt')::boolean, false) = false",
      floor: @charge_floor
    ).update_all(
      "charge = GREATEST(#{@charge_floor.to_f}, charge - #{@charge_decay.to_f})"
    )

    {
      ran_at: started_at,
      duration_ms: ((Time.current - started_at) * 1000).round,
      edges_decayed: edges_decayed,
      nodes_decayed: nodes_decayed,
      edge_decay: @edge_decay,
      charge_decay: @charge_decay,
      charge_floor: @charge_floor
    }
  end
end
