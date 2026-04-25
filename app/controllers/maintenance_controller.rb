class MaintenanceController < ApplicationController
  # POST /decay_sweep
  # Manual trigger for the daily decay pass. Same logic the cron runs.
  def decay_sweep
    result = DecaySweep.new.call
    render json: result
  end

  # GET /stats
  def stats
    render json: {
      embedding_provider: ENV.fetch("EMBEDDING_PROVIDER", "openai"),
      embedding_dimension: Embeddings.dimension,
      nodes: {
        total: Node.count,
        by_type: Node.group(:node_type).count,
        by_integration_state: Node.group(:integration_state).count,
        dormant: Node.where(is_dormant: true).count,
        without_embedding: Node.where(embedding: nil).count,
        average_charge: Node.average(:charge)&.round(4)
      },
      edges: {
        total: Edge.count,
        by_type: Edge.group(:edge_type).count,
        average_weight: Edge.average(:weight)&.round(4)
      }
    }
  end
end
