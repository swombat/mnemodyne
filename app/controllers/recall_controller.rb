class RecallController < ApplicationController
  def create
    result = Recall.new(
      query: params[:query],
      node_activations: params[:node_activations]&.to_unsafe_h,
      seed_node_ids: params[:seed_node_ids],
      node_type_filter: params[:node_type_filter],
      reinforce: params.key?(:reinforce) ? params[:reinforce] : true,
      walk_depth: params[:walk_depth],
      walk_count: params[:walk_count],
      vector_seed_pool: params[:vector_seed_pool],
      base_reinforcement: params[:base_reinforcement],
      rerank_alpha_vector: params[:rerank_alpha_vector],
      rerank_beta_alignment: params[:rerank_beta_alignment],
      rerank_gamma_charge: params[:rerank_gamma_charge]
    ).call

    render json: result
  end

  # POST /recall/by_node
  # Same algorithm but seeds come from a specific node (typically a person- or
  # need-node) instead of vector search. Useful for "who am I with this person".
  def by_node
    node = Node.find(params[:node_id])
    seed_ids = node.outgoing_edges.order(weight: :desc).limit(20).pluck(:target_id)
    seed_ids << node.id

    result = Recall.new(
      seed_node_ids: seed_ids,
      node_activations: params[:node_activations]&.to_unsafe_h&.merge(node.id => 1.0),
      reinforce: params.key?(:reinforce) ? params[:reinforce] : true,
      walk_depth: params[:walk_depth],
      walk_count: params[:walk_count]
    ).call

    render json: result
  end
end
