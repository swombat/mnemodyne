class EdgesController < ApplicationController
  # Idempotent on (source, target, edge_type): if an edge already exists, the
  # weight is increased by min(remaining-to-1.0, weight_increment).
  def create
    p = params.require(:edge).permit(
      :source_id, :target_id, :edge_type, :weight,
      :weight_increment, metadata: {}
    )

    edge = Edge.find_or_initialize_by(
      source_id: p[:source_id],
      target_id: p[:target_id],
      edge_type: p[:edge_type]
    )

    if edge.new_record?
      edge.weight   = p[:weight] || 0.5
      edge.metadata = p[:metadata]&.to_h || {}
      edge.save!
    else
      bump = (p[:weight_increment] || 0.05).to_f
      edge.weight = [(edge.weight + bump), 1.0].min
      edge.metadata = edge.metadata.merge(p[:metadata].to_h) if p[:metadata]
      edge.save!
    end

    render json: { edge: serialize(edge) }, status: :ok
  end

  def update
    edge = Edge.find(params[:id])
    p = params.require(:edge).permit(:weight, metadata: {})
    edge.weight = p[:weight] if p[:weight]
    edge.metadata = edge.metadata.merge(p[:metadata].to_h) if p[:metadata]
    edge.save!
    render json: { edge: serialize(edge) }
  end

  private

  def serialize(edge)
    {
      id: edge.id,
      source_id: edge.source_id,
      target_id: edge.target_id,
      edge_type: edge.edge_type,
      weight: edge.weight,
      metadata: edge.metadata,
      created_at: edge.created_at,
      updated_at: edge.updated_at
    }
  end
end
