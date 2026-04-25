class Edge < ApplicationRecord
  belongs_to :source, class_name: "Node", inverse_of: :outgoing_edges
  belongs_to :target, class_name: "Node", inverse_of: :incoming_edges

  # Open vocabulary; the agent can introduce new types.
  # The conventional list (documented in the spec) covers what we ship with.
  CONVENTIONAL_TYPES = %w[
    theme temporal feeling reminds_of co_retrieved causal
    relates_to_need surfaced_need
    involves_person
    knows family colleague friend
    addresses_need
    relates_to serves
  ].freeze

  validates :edge_type, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validate :no_self_loops

  scope :strong,  ->(min = 0.1) { where("weight >= ?", min) }

  private

  def no_self_loops
    return unless source_id == target_id
    errors.add(:target_id, "must differ from source_id (no self-loops)")
  end
end
