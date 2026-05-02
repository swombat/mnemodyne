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
    walk_depth: 3,
    walk_count: 5,           # number of bins == number of returned results
    walk_seeds_count: 5,     # how many cosine seeds to walk from (random sample)
    vector_seed_pool: 30,
    base_reinforcement: 0.02,
    score_alpha_vector: 0.4,
    score_beta_alignment: 0.3,
    score_gamma_charge: 0.3,
    walk_charge_floor: 0.3,  # minimum charge multiplier in walk weighting (1.0 = pure charge bias, 0.0 = no penalty for low charge). 0.3 = soft preference, low-charge nodes still reachable.
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

    qvec, seed_nodes = embed_and_seed(effective)
    return empty_result(effective, intensity) if seed_nodes.empty?

    # Random sample for walk-starts (no rerank-discard). The walk is the diversity
    # engine; ranking the seeds first would bias the walk toward the constitutional
    # cluster (every node connected to Daniel/to-have-a-sense-of-self would beat
    # any cosine match that wasn't).
    walk_starts  = seed_nodes.sample([@params[:walk_seeds_count], seed_nodes.length].min)
    walked_nodes = walk_from(walk_starts, effective)

    # Candidate pool: walk-starts ∪ walked nodes. The 25 unsampled cosine matches
    # are intentionally dropped — cosine just gave us a starting neighbourhood;
    # the walk does the surfacing.
    candidate_nodes = (walk_starts + walked_nodes).uniq(&:id)
    scored          = candidate_nodes.map { |n| score(n, qvec, effective) }

    # Quintile bins by final_score, one random pick per bin. Forces a spread
    # across the relevance ladder rather than collapsing to top-N.
    final = bin_and_sample(scored, @params[:walk_count])

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

  # Returns [query_embedding, [Node, Node, ...]]. Embedding may be nil when
  # the caller passed seed_node_ids and no query — in that case downstream
  # cosine scoring will fall back to a default value.
  def embed_and_seed(effective)
    if @seed_node_ids.present?
      qvec  = @query.present? ? Embeddings.provider.embed(@query) : nil
      nodes = Node.where(id: @seed_node_ids).active_only.to_a
      [qvec, nodes]
    elsif @query.present?
      qvec  = Embeddings.provider.embed(@query)
      scope = Node.active_only.where.not(embedding: nil)
      scope = scope.where(node_type: Array(@node_type_filter)) if @node_type_filter
      nodes = scope.nearest_neighbors(:embedding, qvec, distance: "cosine")
                   .limit(@params[:vector_seed_pool])
                   .to_a
      [qvec, nodes]
    else
      [nil, []]
    end
  end

  # Score a candidate node uniformly across seeds and walked-to nodes.
  # Cosine is computed against the query embedding when available; otherwise
  # falls back to a neutral 0.5 so it doesn't penalise candidates discovered
  # via explicit seed_node_ids.
  def score(node, qvec, effective)
    align = alignment(node, effective)
    vsim  = if node.respond_to?(:neighbor_distance) && node.neighbor_distance
              1.0 - node.neighbor_distance.to_f
            elsif qvec && node.embedding
              cosine_similarity(qvec, node.embedding)
            else
              0.5
            end
    final = @params[:score_alpha_vector] * vsim +
            @params[:score_beta_alignment] * align +
            @params[:score_gamma_charge] * node.charge
    { node: node, alignment: align, vector_similarity: vsim, final_score: final }
  end

  def cosine_similarity(a, b)
    av = a.is_a?(Array) ? a : a.to_a
    bv = b.is_a?(Array) ? b : b.to_a
    return 0.5 if av.empty? || bv.empty? || av.length != bv.length
    dot = av.each_with_index.sum { |x, i| x * bv[i] }
    na  = Math.sqrt(av.sum { |x| x * x })
    nb  = Math.sqrt(bv.sum { |x| x * x })
    return 0.5 if na.zero? || nb.zero?
    dot / (na * nb)
  end

  # Bin candidates by final_score into n bins of roughly equal size, pick one
  # at random from each bin. Forces a spread across the relevance spectrum.
  # If we have fewer candidates than bins, return them all (sorted).
  def bin_and_sample(scored, n_bins)
    return scored.sort_by { |r| -r[:final_score] } if scored.length <= n_bins

    sorted = scored.sort_by { |r| -r[:final_score] }
    bin_size = sorted.length.to_f / n_bins
    (0...n_bins).map do |i|
      start_idx = (i * bin_size).floor
      end_idx   = ((i + 1) * bin_size).floor - 1
      end_idx   = sorted.length - 1 if i == n_bins - 1
      bin = sorted[start_idx..end_idx]
      bin.sample
    end.compact
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

  # Walks from each seed node up to walk_depth hops, biased (softly) by edge
  # weight, target node charge, and target activation. Returns the array of
  # Node objects walked to. The visited set prevents cycles within a single
  # call. Charge bias is softened via walk_charge_floor so low-charge nodes
  # are less likely but not effectively unreachable.
  def walk_from(seed_nodes, effective)
    visited = seed_nodes.map(&:id).to_set
    out = []

    floor = @params[:walk_charge_floor]
    span  = 1.0 - floor

    seed_nodes.each do |seed|
      current = seed
      @params[:walk_depth].times do
        edges = Edge.where(source_id: current.id).where.not(target_id: visited.to_a)
                    .pluck(:target_id, :weight)
        break if edges.empty?

        target_ids   = edges.map(&:first)
        target_nodes = Node.where(id: target_ids).active_only.index_by(&:id)
        weights = edges.map do |target_id, edge_weight|
          tnode = target_nodes[target_id]
          next 0.0 unless tnode
          # Soft charge bias: charge_factor in [floor, 1.0]
          charge_factor = floor + span * tnode.charge
          edge_weight * charge_factor * (1.0 + (effective[target_id] || 0.0))
        end
        total = weights.sum
        break if total.zero?

        chosen_target_id = weighted_sample(target_ids, weights, total)
        chosen = target_nodes[chosen_target_id]
        break unless chosen

        out << chosen
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
