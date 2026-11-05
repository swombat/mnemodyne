# Recall — the workhorse retrieval service.
#
# Pipeline (see memory_service_spec_v2.md §4):
#   1. Build effective activation vector  (request + baselines)
#   2. Compute request_intensity          (L2 norm of effective)
#   3. Seed selection                     (provided ids OR vector search)
#   4. Re-rank seeds                      (α·vector + β·alignment + γ·charge)
#   5. Walk                               (weighted random walk, depth D)
#   6. Collect + dedup
#   7. Curate                             (spread: "score" → quintile bins;
#                                          spread: "distance" → anchor + BFS layers)
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
    hebbian_base: 0.1,
    # spread: how the returned set is chosen from the candidate pool.
    #   "score"    — the original: quintile bins by final_score, one random pick
    #                per bin. Since 2026-11-05 the closest seed by similarity is
    #                returned first and the bins fill the remaining slots.
    #   "distance" — anchor + layers (2026-09-06, proposed by Daniel): the
    #                closest vector seed is always returned (distance 0), then
    #                the best-scored node at exactly 1 hop, 2 hops, … over
    #                *authored* edges, hubs (need/person) traversed but not
    #                returned. Diversity is structural and legible: each result
    #                carries its `distance` from the anchor.
    spread: "score",
    spread_max_depth: 6,
    # Hebbian co_retrieved edges make the graph a small world (41k of Lume's 50k
    # edges); with them counted, everything is ≤2 hops from everything and
    # "distance" means nothing. Distance is measured over authored edges only.
    spread_ignored_edge_types: %w[co_retrieved].freeze,
    # Lexical channel (2026-11-05): a query term that appears, as a whole word,
    # in at most lexical_max_df returnable nodes reserves up to lexical_slots
    # places after the anchor. An embedding of one name does not single out
    # the one memory that contains it; a word-boundary match does.
    lexical_slots: 2,
    lexical_max_df: 3,
    lexical_max_terms: 24
  }.freeze

  # Node types traversed as connectors but never returned in a distance layer.
  # One hop from any memory is usually its need or its person; the layer
  # semantics are: 1 = explicitly linked memory, 2 = shares a hub, 3 = neighbourhood.
  HUB_TYPES = %w[need person].freeze
  SHORT_QUERY_WORDS = 3
  SPREADS   = %w[score distance].freeze

  attr_reader :params

  def initialize(query: nil, node_activations: {}, seed_node_ids: nil,
                 node_type_filter: nil, reinforce: true, exclude_node_ids: nil, **overrides)
    @query             = query
    @node_activations  = (node_activations || {}).transform_keys(&:to_s).transform_values(&:to_f)
    @seed_node_ids     = seed_node_ids
    @node_type_filter  = node_type_filter
    @reinforce         = reinforce
    # Session-level dedupe belongs server-side: in distance mode the anchor
    # must be chosen among nodes NOT already surfaced, or the whole chain hangs
    # off something the caller is about to discard.
    @exclude_node_ids  = Array(exclude_node_ids).map(&:to_s).to_set
    @params            = DEFAULTS.merge(overrides.compact.symbolize_keys)
    raise ArgumentError, "spread must be one of #{SPREADS.join(', ')}" unless SPREADS.include?(@params[:spread].to_s)
  end

  def call
    effective    = build_effective_activations
    intensity    = l2_norm(effective.values)

    qvec, seed_nodes = embed_and_seed(effective)
    return empty_result(effective, intensity) if seed_nodes.empty?

    final = if @params[:spread].to_s == "distance"
      distance_spread(seed_nodes, qvec, effective)
    else
      score_spread(seed_nodes, qvec, effective)
    end

    apply_reinforcement(final, intensity) if @reinforce
    apply_hebbian(final, intensity)       if @reinforce && final.length > 1

    {
      effective_activations: effective,
      request_intensity: intensity,
      spread: @params[:spread].to_s,
      results: final.map { |r| serialize(r) }
    }
  end

  private

  # The original curation: walk, pool, quintile-bin by score, one random pick per bin.
  # With a query, the closest seed by vector similarity is the anchor: always a
  # walk start and always returned first. Gravity (charge, need alignment) orders
  # and samples the rest; it must not displace the match (2026-11-05: an exact
  # content query returned its own node in 12/250 trials before this).
  def score_spread(seed_nodes, qvec, effective)
    seeds  = seed_nodes.reject { |n| @exclude_node_ids.include?(n.id) }
    anchor = query_anchor(seeds, qvec, effective)

    # Random sample for walk-starts (no rerank-discard). The walk is the diversity
    # engine; ranking the seeds first would bias the walk toward the constitutional
    # cluster (every node connected to Daniel/to-have-a-sense-of-self would beat
    # any cosine match that wasn't).
    walk_starts  = seed_nodes.sample([@params[:walk_seeds_count], seed_nodes.length].min)
    if anchor && walk_starts.none? { |n| n.id == anchor[:node].id }
      walk_starts = [anchor[:node]] + walk_starts.first([walk_starts.length - 1, 0].max)
    end
    walked_nodes = walk_from(walk_starts, effective)

    # Candidate pool: walk-starts ∪ walked nodes. The 25 unsampled cosine matches
    # are intentionally dropped — cosine just gave us a starting neighbourhood;
    # the walk does the surfacing.
    candidate_nodes = (walk_starts + walked_nodes).uniq(&:id)
                        .reject { |n| @exclude_node_ids.include?(n.id) }
    reserved = [anchor].compact
    reserved += lexical_matches(except: reserved.map { |r| r[:node].id })
                  .first([@params[:walk_count] - reserved.length, 0].max)
                  .map { |n| score(n, qvec, effective).merge(match: "lexical") }
    reserved_ids    = reserved.map { |r| r[:node].id }.to_set
    candidate_nodes = candidate_nodes.reject { |n| reserved_ids.include?(n.id) }
    scored          = candidate_nodes.map { |n| score(n, qvec, effective) }

    # Quintile bins by final_score, one random pick per bin. Forces a spread
    # across the relevance ladder rather than collapsing to top-N.
    reserved + bin_and_sample(scored, @params[:walk_count] - reserved.length)
  end

  # Returnable nodes containing the query's rarest whole-word terms, rarest
  # term first. Terms in more than lexical_max_df nodes say nothing specific
  # and are ignored. Hubs (need/person) are not returned, as in the layers.
  def lexical_matches(except: [])
    slots = @params[:lexical_slots].to_i
    return [] if @query.blank? || slots <= 0
    words = @query.scan(/[[:alnum:]][[:alnum:]_'-]*/)
    # A short query is probably a name: then two- and three-letter words count too.
    min_length = words.length <= SHORT_QUERY_WORDS ? 2 : 4
    terms = words.select { |w| w.length >= min_length }.map(&:downcase).uniq
                 .max_by(@params[:lexical_max_terms].to_i, &:length)
    return [] if terms.empty?

    scope = Node.active_only
    scope = @node_type_filter ? scope.where(node_type: Array(@node_type_filter)) : scope.where.not(node_type: HUB_TYPES)
    scope = scope.where.not(id: (@exclude_node_ids.to_a + except).uniq) if @exclude_node_ids.any? || except.any?
    patterns = terms.map { |t| "\\m#{t.gsub(/[^[:alnum:]_'-]/, "")}\\M" }
    counts = scope.pick(*patterns.map { |pat| Arel.sql(Node.sanitize_sql_array(["count(*) FILTER (WHERE content ~* ?)", pat])) })
    counts = Array(counts)
    rare = patterns.zip(counts).select { |_, c| c.to_i.between?(1, @params[:lexical_max_df].to_i) }.sort_by(&:last)

    picked = []
    rare.each do |pat, _|
      scope.where("content ~* ?", pat).order(charge: :desc).limit(slots).each do |n|
        picked << n unless picked.any? { |m| m.id == n.id }
      end
      break if picked.length >= slots
    end
    picked.first(slots)
  end

  # The seed closest to the query by measured vector similarity, or nil when
  # there is no query vector or no seed has one (seed_node_ids without a query,
  # or only unembedded seeds, keep gravity's choice). score()'s 0.5 fallback for
  # a missing vector is not a measurement and must not win the anchor.
  def query_anchor(seeds, qvec, effective)
    return nil unless qvec
    # A node whose text is the query is the match whatever the embedder says
    # (a node's vector also carries its description). Same scope as the seeds:
    # explicit seed ids when given, otherwise the active graph. Duplicates:
    # closest vector, then id.
    if (exact = exact_text_match(qvec))
      return score(exact, qvec, effective).merge(match: "anchor")
    end
    # Similarity only (no alignment queries) to pick; then score the one winner.
    best = seeds.filter_map { |n| (sim = measured_similarity(n, qvec)) && [n, sim] }.max_by(&:last)
    best && score(best.first, qvec, effective).merge(match: "anchor")
  end

  def exact_text_match(qvec)
    wanted = @query.to_s.unicode_normalize(:nfkc).downcase.split.join(" ")
    return nil if wanted.empty?
    scope = Node.active_only.where("lower(regexp_replace(btrim(content), '\\s+', ' ', 'g')) = ?", wanted)
    scope = scope.where(id: @seed_node_ids) if @seed_node_ids.present?
    scope = @node_type_filter ? scope.where(node_type: Array(@node_type_filter)) : scope.where.not(node_type: HUB_TYPES)
    scope = scope.where.not(id: @exclude_node_ids.to_a) if @exclude_node_ids.any?
    scope.to_a.min_by { |n| [-(measured_similarity(n, qvec) || -2.0), n.id] }
  end

  def measured_similarity(node, qvec)
    if node.respond_to?(:neighbor_distance) && node.neighbor_distance
      1.0 - node.neighbor_distance.to_f
    elsif node.embedding.present? && node.embedding.to_a.length == qvec.length
      cosine_similarity(qvec, node.embedding)
    end
  end

  # Anchor + layers. Returns up to walk_count scored rows, each tagged with
  # :distance (0 = anchor). Gravity (charge, need alignment) acts as the ranking
  # WITHIN a layer rather than as path-sampling bias; the only randomness left
  # is upstream, in the query. A sparse graph runs out of layers early and
  # returns fewer results — honestly, rather than padding a layer twice.
  def distance_spread(seed_nodes, qvec, effective)
    seeds = seed_nodes.reject { |n| @exclude_node_ids.include?(n.id) }
    return [] if seeds.empty?

    # The anchor is the match: closest by vector similarity when there is a
    # query, gravity's pick only when there isn't. Gravity still orders each
    # layer below.
    anchor = query_anchor(seeds, qvec, effective) ||
             seeds.map { |n| score(n, qvec, effective) }.max_by { |r| r[:final_score] }
    anchor[:distance] = 0
    results  = [anchor]
    lexical_matches(except: [anchor[:node].id]).first([@params[:walk_count] - 1, 0].max).each do |n|
      results << score(n, qvec, effective).merge(match: "lexical", distance: nil)
    end
    # Traversal and result dedup are separate: a lexically reserved node is
    # still walked through, so reserving it cannot cut the anchor's paths.
    returned = Set.new(results.map { |r| r[:node].id })
    visited  = Set[anchor[:node].id]
    frontier = [anchor[:node].id]
    ignored  = Array(@params[:spread_ignored_edge_types])
    depth    = 0

    while results.length < @params[:walk_count] && frontier.any? && depth < @params[:spread_max_depth]
      depth += 1
      edges = Edge.where("source_id IN (?) OR target_id IN (?)", frontier, frontier)
      edges = edges.where.not(edge_type: ignored) if ignored.any?
      touched = edges.pluck(:source_id, :target_id).flatten.uniq - visited.to_a
      break if touched.empty?

      # Dormant nodes are neither traversed nor returned (same rule as the walk).
      layer = Node.where(id: touched).active_only.to_a
      visited.merge(touched)                    # dormant ids too: never re-expand them
      frontier = layer.map(&:id)
      break if visited.size > 5_000             # bound the BFS on dense graphs

      returnable = layer.reject { |n| @exclude_node_ids.include?(n.id) || returned.include?(n.id) }
      returnable = if @node_type_filter
        returnable.select { |n| Array(@node_type_filter).include?(n.node_type) }
      else
        returnable.reject { |n| HUB_TYPES.include?(n.node_type) }
      end
      best = returnable.map { |n| score(n, qvec, effective) }.max_by { |r| r[:final_score] }
      next unless best                           # hub-only layer: keep expanding

      best[:distance] = depth
      results << best
      returned << best[:node].id
    end

    results
  end

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
      next unless delta.positive?
      new_charge = (r[:node].charge + delta).clamp(0.0, 1.0)
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
      distance: r[:distance],
      match: r[:match],
      applied_reinforcement: r[:applied_reinforcement]&.round(6)
    }
  end
end
