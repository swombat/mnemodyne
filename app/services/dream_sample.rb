require "securerandom"

# Uniform reservoir sample: O(N) ids scanned, O(n) retained; bodies/embeddings are
# never loaded. A stable id order plus seed reproduces selection for a fixed pool.
class DreamSample
  def self.call(n:, seed:, include_dormant: true)
    Node.transaction(isolation: :repeatable_read) do
      private_people = Node.persons.where("metadata @> ?::jsonb", { privacy_level: "high" }.to_json)
      links = Edge.where(edge_type: "involves_person")
      scope = Node.memories
        .where.not("metadata @> ?::jsonb", { dream_exempt: true }.to_json)
        .where.not(id: links.where(target_id: private_people.select(:id)).select(:source_id))
        .where.not(id: links.where(source_id: private_people.select(:id)).select(:target_id))
      scope = scope.active_only unless include_dormant

      rng = Random.new(seed)
      ids = []
      count = 0
      scope.select(:id).find_each do |node|
        count += 1
        if ids.length < n
          ids << node.id
        else
          index = rng.rand(count)
          ids[index] = node.id if index < n
        end
      end
      # Randomise presentation order too, even when the pool fits entirely.
      ids.shuffle!(random: rng)
      by_id = Node.where(id: ids).select(:id, :node_type, :content, :source_uris, :is_dormant).index_by(&:id)
      {
        seed: seed, requested_n: n, eligible_count: count,
        nodes: ids.map { |id| by_id.fetch(id).attributes },
        include_dormant: include_dormant
      }
    end
  end
end
