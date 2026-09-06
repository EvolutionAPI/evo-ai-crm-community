class ScheduledPostsProcessorJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(scheduled_post_id = nil)
    if scheduled_post_id
      process_single(scheduled_post_id)
    else
      process_due
    end
  end

  private

  def process_single(scheduled_post_id)
    scheduled_post = ScheduledPost.find_by(id: scheduled_post_id)
    return unless scheduled_post

    ScheduledPosts::ExecutorService.new(scheduled_post).execute
  end

  def process_due
    due_posts = ScheduledPost.due.limit(100)
    Rails.logger.info "ScheduledPostsProcessorJob: found #{due_posts.count} due scheduled posts"

    due_posts.find_each do |scheduled_post|
      ScheduledPosts::ExecutorService.new(scheduled_post).execute
    rescue StandardError => e
      Rails.logger.error "ScheduledPostsProcessorJob: error processing #{scheduled_post.id}: #{e.message}"
    end
  end
end
