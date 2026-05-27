# == Schema Information
#
# Table name: macro_executions
#
#  id              :uuid             not null, primary key
#  actions_result  :jsonb
#  completed_at    :datetime
#  error_message   :text
#  status          :integer          default("pending"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  conversation_id :uuid             not null
#  macro_id        :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_macro_executions_on_conversation_id                 (conversation_id)
#  index_macro_executions_on_conversation_id_and_created_at  (conversation_id,created_at)
#  index_macro_executions_on_macro_id                        (macro_id)
#  index_macro_executions_on_status                          (status)
#  index_macro_executions_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (macro_id => macros.id)
#  fk_rails_...  (user_id => users.id)
#
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
