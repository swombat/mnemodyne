# Recall — the workhorse retrieval service.
#
# Pipeline (see memory_service_spec_v2.md §4):
#   1. Build effective activation vector  (request + baselines)
#   2. Compute request_intensity          (L2 norm of effective)
#   3. Seed selection                     (provided ids OR vector search)
#   4. Re-rank seeds                      (α·vector + β·alignment + γ·charge)
#   5. Walk                               (weighted random walk, depth D)
#   6. Collect + dedup
#   7. Curate top N by final_score
#   8. Reinforce charges                  (intensity × alignment × base)
#   9. Hebbian wire pairs that co-surfaced
#  10. (caller) write a log row if it wants
#  11. Return enriched results
#
# All judgment lives upstream in the agent. This service is mechanical.
class Recall
  DEFAULTS = {
    walk_depth: 2,
    walk_count: 10,
    vector_seed_pool: 30,
    base_reinforcement: 0.02,
    rerank_alpha_vector: 0.4,
    rerank_beta_alignment: 0.4,
    rerank_gamma_charge: 0.2,
    hebbian_base: 0.1
  }.freeze

  attr_reader :params

  def initialize(query: nil, node_activations: {}, seed_node_ids: nil,
                 node_type_filter: nil, reinforce: true, **overrides)
    @query             = query
    @node_activations  = (node_activations || {}).transform_keys(&:to_s).transform_values(&:to_f)
    @seed_node_ids     = seed_node_ids
    @node_type_filter  = node_type_filter
    @reinforce         = reinforce
    @params            = DEFAULTS.merge(overrides.compact.symbolize_keys)
  end

  def call
    effective    = build_effective_activations
    intensity    = l2_norm(effective.values)

    seeds        = select_seeds(effective)
    return empty_result(effective, intensity) if seeds.empty?

    ranked_seeds = rerank(seeds, effective)
    walk_results = walk_from(ranked_seeds.first(@params[:walk_count] / 2), effective)

    candidates   = (ranked_seeds + walk_results).uniq { |row| row[:node].id }
    final        = candidates.sort_by { |r| -r[:final_score] }.first(@params[:walk_count])

    apply_reinforcement(final, intensity) if @reinforce
    apply_hebbian(final, intensity)       if @reinforce && final.length > 1

    {
      effective_activations: effective,
      request_intensity: intensity,
      results: final.map { |r| serialize(r) }
    }
  end

  private

  def build_effective_activations
    explicit = @node_activations.dup

    # Add baseline-activated constitutional nodes (always-warm needs etc.)
    Node.where("(metadata->>'baseline_activation')::float > 0").find_each do |n|
      explicit[n.id] = [(explicit[n.id] || 0.0), n.baseline_activation].max
    end

    explicit
  end

  def l2_norm(values)
    Math.sqrt(values.sum { |v| v * v })
  end

  def select_seeds(effective)
    if @seed_node_ids.present?
      Node.where(id: @seed_node_ids).active_only.to_a
    elsif @query.present?
      qvec = Embeddings.provider.embed(@query)
      scope = Node.active_only.where.not(embedding: nil)
      scope = scope.where(node_type: Array(@node_type_filter)) if @node_type_filter
      scope.nearest_neighbors(:embedding, qvec, distance: "cosine")
           .limit(@params[:vector_seed_pool])
           .to_a
    else
      []
    end
  end

  def rerank(seeds, effective)
    seeds.map do |node|
      align = alignment(node, effective)
      vsim  = node.respond_to?(:neighbor_distance) ? (1.0 - node.neighbor_distance.to_f) : 0.5
      score = @params[:rerank_alpha_vector] * vsim +
              @params[:rerank_beta_alignment] * align +
              @params[:rerank_gamma_charge] * node.charge
      { node: node, alignment: align, vector_similarity: vsim, final_score: score }
    end.sort_by { |r| -r[:final_score] }
  end

  # Alignment(M) = sum over edges (M → N) where N is currently active:
  #   activation[N] * edge.weight
  # then normalised by the sum of activations (so scale stays in [0, ~1]).
  def alignment(node, effective)
    return 0.0 if effective.empty?

    relevant_edges = Edge.where(source_id: node.id, target_id: effective.keys)
                         .pluck(:target_id, :weight)
    raw = relevant_edges.sum { |target_id, weight| (effective[target_id] || 0.0) * weight }
    norm = effective.values.sum
    norm.positive? ? (raw / norm) : 0.0
  end

  def walk_from(seed_results, effective)
    visited = seed_results.map { |r| r[:node].id }.to_set
    out = []

    seed_results.each do |seed|
      current = seed[:node]
      @params[:walk_depth].times do
        edges = Edge.where(source_id: current.id).where.not(target_id: visited.to_a)
                    .pluck(:target_id, :weight)
        break if edges.empty?

        target_ids = edges.map(&:first)
        target_nodes = Node.where(id: target_ids).active_only.index_by(&:id)
        weights = edges.map do |target_id, edge_weight|
          tnode = target_nodes[target_id]
          next 0.0 unless tnode
          edge_weight * tnode.charge * (1.0 + (effective[target_id] || 0.0))
        end
        total = weights.sum
        break if total.zero?

        chosen_target_id = weighted_sample(target_ids, weights, total)
        chosen = target_nodes[chosen_target_id]
        break unless chosen

        out << {
          node: chosen,
          alignment: alignment(chosen, effective),
          vector_similarity: 0.0,
          final_score: @params[:rerank_beta_alignment] * alignment(chosen, effective) +
                       @params[:rerank_gamma_charge] * chosen.charge
        }
        visited << chosen.id
        current = chosen
      end
    end

    out
  end

  def weighted_sample(items, weights, total)
    threshold = rand * total
    cumulative = 0.0
    items.each_with_index do |item, i|
      cumulative += weights[i]
      return item if cumulative >= threshold
    end
    items.last
  end

  def apply_reinforcement(results, intensity)
    return if intensity.zero?

    max_align = results.map { |r| r[:alignment] }.max.to_f
    max_align = 1.0 if max_align.zero?

    results.each do |r|
      delta = @params[:base_reinforcement] * intensity * (r[:alignment] / max_align)
      next if delta.zero?
      new_charge = [r[:node].charge + delta, 1.0].min
      r[:node].update_columns(charge: new_charge, updated_at: Time.current)
      r[:applied_reinforcement] = delta
    end
  end

  def apply_hebbian(results, intensity)
    weight = @params[:hebbian_base] * intensity
    return if weight <= 0.0

    ids = results.map { |r| r[:node].id }
    pairs = ids.combination(2).to_a

    existing = Edge.where(edge_type: "co_retrieved")
                   .where(source_id: ids, target_id: ids)
                   .pluck(:source_id, :target_id)
                   .to_set

    Edge.transaction do
      pairs.each do |a, b|
        next if existing.include?([a, b]) || existing.include?([b, a])
        Edge.create!(source_id: a, target_id: b, edge_type: "co_retrieved",
                     weight: [weight, 1.0].min)
      end
    end
  end

  def empty_result(effective, intensity)
    { effective_activations: effective, request_intensity: intensity, results: [] }
  end

  def serialize(r)
    n = r[:node]
    {
      id: n.id,
      node_type: n.node_type,
      content: n.content,
      description: n.description,
      charge: n.charge,
      integration_state: n.integration_state,
      source_uris: n.source_uris,
      metadata: n.metadata,
      vector_similarity: r[:vector_similarity].round(4),
      alignment: r[:alignment].round(4),
      final_score: r[:final_score].round(4),
      applied_reinforcement: r[:applied_reinforcement]&.round(6)
    }
  end
end
