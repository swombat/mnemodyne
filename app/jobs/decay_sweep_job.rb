class DecaySweepJob < ApplicationJob
  queue_as :default

  def perform
    result = DecaySweep.new.call
    Rails.logger.info "[DecaySweepJob] #{result.to_json}"
    result
  end
end
