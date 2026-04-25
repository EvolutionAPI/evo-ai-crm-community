class AddSentimentAnalysisFieldsToFacebookCommentModerations < ActiveRecord::Migration[7.1]
  def change
    add_column :facebook_comment_moderations, :sentiment_offensive, :boolean, default: false, null: false, if_not_exists: true
    add_column :facebook_comment_moderations, :sentiment_confidence, :float, default: 0.0, null: false, if_not_exists: true
    add_column :facebook_comment_moderations, :sentiment_reason, :text, if_not_exists: true
  end
end

