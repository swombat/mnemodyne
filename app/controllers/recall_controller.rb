class RecallController < ApplicationController
  def create
    result = Recall.new(
      query: params[:query],
      node_activations: params[:node_activations]&.to_unsafe_h,
      seed_node_ids: params[:seed_node_ids],
      node_type_filter: params[:node_type_filter],
      reinforce: bool_param(:reinforce, default: true),
      walk_depth: int_param(:walk_depth),
      walk_count: int_param(:walk_count),
      vector_seed_pool: int_param(:vector_seed_pool),
      base_reinforcement: float_param(:base_reinforcement),
      score_alpha_vector: float_param(:rerank_alpha_vector),
      score_beta_alignment: float_param(:rerank_beta_alignment),
      score_gamma_charge: float_param(:rerank_gamma_charge)
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
      reinforce: bool_param(:reinforce, default: true),
      walk_depth: int_param(:walk_depth),
      walk_count: int_param(:walk_count)
    ).call

    render json: result
  end

  private

  # Numeric params may arrive as JSON numbers or as strings (form-encoded
  # clients, sloppy callers). Coerce valid values; turn garbage into nil so
  # Recall's `overrides.compact` falls back to DEFAULTS instead of the
  # request 500ing mid-arithmetic — and instead of `"banana".to_f` silently
  # zeroing a scoring weight.
  def float_param(key)
    Float(params[key], exception: false)
  end

  def int_param(key)
    Integer(params[key], exception: false)
  end

  # `reinforce: "false"` from a form-encoded client is a truthy String —
  # without casting, a caller explicitly asking not to mutate the graph
  # would silently reinforce anyway.
  def bool_param(key, default:)
    return default unless params.key?(key)

    value = ActiveModel::Type::Boolean.new.cast(params[key])
    value.nil? ? default : value
  end
end
