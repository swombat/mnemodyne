class RecallController < ApplicationController
  def create
    result = Recall.new(
      query: params[:query],
      node_activations: params[:node_activations]&.to_unsafe_h,
      seed_node_ids: params[:seed_node_ids],
      node_type_filter: params[:node_type_filter],
      reinforce: bool_param(:reinforce, default: true),
      exclude_node_ids: id_list_param(:exclude_node_ids),
      spread: enum_param(:spread, Recall::SPREADS),
      spread_max_depth: int_param(:spread_max_depth, min: 1, max: 10),
      walk_depth: int_param(:walk_depth, min: 0),
      walk_count: int_param(:walk_count, min: 1),
      vector_seed_pool: int_param(:vector_seed_pool, min: 1),
      base_reinforcement: float_param(:base_reinforcement, min: 0.0),
      score_alpha_vector: float_param(:rerank_alpha_vector, min: 0.0),
      score_beta_alignment: float_param(:rerank_beta_alignment, min: 0.0),
      score_gamma_charge: float_param(:rerank_gamma_charge, min: 0.0)
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
      exclude_node_ids: id_list_param(:exclude_node_ids),
      spread: enum_param(:spread, Recall::SPREADS),
      spread_max_depth: int_param(:spread_max_depth, min: 1, max: 10),
      walk_depth: int_param(:walk_depth, min: 0),
      walk_count: int_param(:walk_count, min: 1)
    ).call

    render json: result
  end

  private

  # Numeric params may arrive as JSON numbers or as strings (form-encoded
  # clients, sloppy callers). Coerce valid values; turn malformed or
  # out-of-domain values into nil so Recall's `overrides.compact` falls back
  # to DEFAULTS instead of the
  # request 500ing mid-arithmetic — and instead of `"banana".to_f` silently
  # zeroing a scoring weight.
  def float_param(key, min: nil, max: nil)
    value = Float(params[key], exception: false)
    return unless value&.finite?
    return if min && value < min
    return if max && value > max

    value
  end

  def int_param(key, min: nil, max: nil)
    raw = params[key]
    return if raw.is_a?(Numeric) && raw.to_i != raw

    value = Integer(raw, exception: false)
    return if min && value && value < min
    return if max && value && value > max

    value
  end

  # Unknown spread names fall back to the default rather than 400ing; the
  # response echoes the spread actually used.
  def enum_param(key, allowed)
    value = params[key].to_s
    allowed.include?(value) ? value : nil
  end

  # Session-seen ids from the caller. Bounded so a runaway client can't ship
  # its whole history in every request; non-UUID entries are dropped.
  def id_list_param(key, max: 500)
    Array(params[key]).map(&:to_s).select { |v| v.match?(/\A[0-9a-f-]{36}\z/i) }.first(max)
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
