class NodesController < ApplicationController
  def index
    nodes = Node.all
    nodes = nodes.where(node_type: params[:type])                if params[:type].present?
    nodes = nodes.where(integration_state: params[:integration_state]) if params[:integration_state].present?
    nodes = nodes.where("charge >= ?", params[:min_charge].to_f) if params[:min_charge].present?
    nodes = nodes.where(is_dormant: ActiveModel::Type::Boolean.new.cast(params[:dormant])) \
            if params.key?(:dormant)
    nodes = nodes.where("content = ?", params[:name])            if params[:name].present?
    if params[:updated_since].present?
      nodes = nodes.where("updated_at >= ?", Time.parse(params[:updated_since]))
    end

    nodes = nodes.order(charge: :desc).limit(limit_param)

    render json: { nodes: nodes.map { |n| serialize(n) } }
  end

  def show
    render json: { node: serialize(Node.find(params[:id])) }
  end

  def create
    node = nil
    Node.transaction do
      node_attrs = params.require(:node).permit(
        :node_type, :content, :description, :charge,
        :integration_state, :is_dormant,
        source_uris: [],
        metadata: {}
      ).to_h
      node = Node.create!(node_attrs)

      Array(params[:edges]).each do |edge_params|
        ep = edge_params.permit(:target_id, :edge_type, :weight, metadata: {}).to_h
        Edge.create!(
          source_id: node.id,
          target_id: ep[:target_id],
          edge_type: ep[:edge_type],
          weight: ep[:weight] || 0.5,
          metadata: ep[:metadata] || {}
        )
      end
    end
    render json: { node: serialize(node) }, status: :created
  end

  def update
    node = Node.find(params[:id])
    attrs = params.require(:node).permit(
      :content, :description, :charge,
      :integration_state, :is_dormant,
      source_uris: [],
      metadata: {}
    ).to_h

    if attrs["integration_state"] && attrs["integration_state"] != node.integration_state
      attrs["state_changed_at"] = Time.current
    end

    node.update!(attrs)
    render json: { node: serialize(node) }
  end

  def edges
    node = Node.find(params[:id])
    out  = node.outgoing_edges.includes(:target).map { |e| serialize_edge(e) }
    inn  = node.incoming_edges.includes(:source).map { |e| serialize_edge(e) }
    render json: { node_id: node.id, outgoing: out, incoming: inn }
  end

  private

  def limit_param
    raw = params[:limit].to_i
    raw = 100 if raw <= 0     # default if missing or invalid
    [raw, 500].min            # hard cap
  end

  def serialize(n)
    {
      id: n.id,
      node_type: n.node_type,
      content: n.content,
      description: n.description,
      charge: n.charge,
      integration_state: n.integration_state,
      state_changed_at: n.state_changed_at,
      is_dormant: n.is_dormant,
      source_uris: n.source_uris,
      metadata: n.metadata,
      embedding_present: !n.embedding.nil?,
      created_at: n.created_at,
      updated_at: n.updated_at
    }
  end

  def serialize_edge(edge)
    other = edge.source_id == params[:id] ? edge.target : edge.source
    {
      edge_id: edge.id,
      direction: edge.source_id == params[:id] ? "out" : "in",
      edge_type: edge.edge_type,
      weight: edge.weight,
      metadata: edge.metadata,
      other_node: { id: other.id, node_type: other.node_type, content: other.content }
    }
  end
end
