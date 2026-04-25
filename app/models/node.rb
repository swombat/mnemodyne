class Node < ApplicationRecord
  has_neighbors :embedding

  TYPES = %w[memory need person].freeze
  INTEGRATION_STATES = %w[raw active integrated constitutional].freeze

  has_many :outgoing_edges,
           class_name: "Edge",
           foreign_key: :source_id,
           dependent: :destroy,
           inverse_of: :source

  has_many :incoming_edges,
           class_name: "Edge",
           foreign_key: :target_id,
           dependent: :destroy,
           inverse_of: :target

  has_many :neighbors_out,
           through: :outgoing_edges,
           source: :target

  has_many :neighbors_in,
           through: :incoming_edges,
           source: :source

  validates :node_type, presence: true, inclusion: { in: TYPES }
  validates :content, presence: true
  validates :charge, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :integration_state, inclusion: { in: INTEGRATION_STATES }
  validates :content,
            uniqueness: { scope: :node_type, case_sensitive: false },
            if: -> { node_type.in?(%w[need person]) }
  validate  :validate_metadata_for_type

  scope :memories,    -> { where(node_type: "memory") }
  scope :needs,       -> { where(node_type: "need") }
  scope :persons,     -> { where(node_type: "person") }
  scope :active_only, -> { where(is_dormant: false) }

  after_create_commit :enqueue_embedding
  after_update_commit :enqueue_embedding_if_text_changed

  def memory? = node_type == "memory"
  def need?   = node_type == "need"
  def person? = node_type == "person"

  # The text fed to the embedding provider. Memory: content + why_line.
  # Need / person: content + description (which serves as the long form).
  def embedding_text
    [content.to_s, description.to_s.presence].compact.join(" — ")
  end

  # Baseline activation for this node as a gravitational source. Constitutional
  # nodes (e.g. identity-need) carry charge into every retrieval even when the
  # agent doesn't explicitly activate them.
  def baseline_activation
    metadata.fetch("baseline_activation", 0.0).to_f
  end

  def decay_exempt?
    metadata.fetch("decay_exempt", false) ||
      integration_state == "constitutional"
  end

  private

  def enqueue_embedding
    EmbedNodeJob.perform_later(id)
  end

  def enqueue_embedding_if_text_changed
    return unless saved_change_to_content? || saved_change_to_description?
    enqueue_embedding
  end

  def validate_metadata_for_type
    case node_type
    when "person"
      # Persons benefit from a privacy_level marker; don't enforce in v1.
    when "need"
      bl = metadata["baseline_activation"]
      if bl && (!bl.is_a?(Numeric) || bl.negative? || bl > 1.0)
        errors.add(:metadata, "baseline_activation must be a number in [0, 1]")
      end
    end
  end
end
