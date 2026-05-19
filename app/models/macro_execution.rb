class MacroExecution < ApplicationRecord
  belongs_to :macro
  belongs_to :conversation
  belongs_to :user

  enum status: { pending: 0, success: 1, failed: 2 }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_conversation, ->(conversation) { where(conversation: conversation) }

  def complete!(actions_result: [])
    update!(
      status: :success,
      completed_at: Time.current,
      actions_result: actions_result
    )
  end

  def fail!(error:, actions_result: [])
    update!(
      status: :failed,
      completed_at: Time.current,
      error_message: error.to_s.truncate(1000),
      actions_result: actions_result
    )
  end
end
