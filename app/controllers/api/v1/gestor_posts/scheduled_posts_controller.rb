module Api
  module V1
    module GestorPosts
      class ScheduledPostsController < BaseController
        before_action :require_social_channel!, only: [:create]

        def index
          posts = ::ScheduledPost.where(created_by: current_user.id).recent.limit(50)
          render json: { success: true, data: posts.as_json(only: post_fields) }
        end

        def create
          post = ::ScheduledPost.new(
            created_by: current_user.id,
            caption: params[:caption],
            platforms: Array(params[:platforms]),
            content_type: params[:content_type],
            channel_type: social_channel.class.name,
            channel_id: social_channel.id.to_s,
            scheduled_for: params[:scheduled_for]
          )

          if params[:media].blank?
            return render json: { success: false, errors: ['Arquivo de mídia é obrigatório.'] }, status: :unprocessable_entity
          end

          # Anexa a mídia só depois do save: como scheduled_for tem validação
          # (não pode estar no passado), tentar anexar num registro que ainda
          # pode falhar a validação deixa a attachment órfã sem record_id.
          if post.save
            post.media.attach(params[:media])
            render json: { success: true, data: post.as_json(only: post_fields) }, status: :created
          else
            render json: { success: false, errors: post.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def cancel
          post = ::ScheduledPost.find(params[:id])
          post.mark_as_cancelled!
          render json: { success: true, data: post.as_json(only: post_fields) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Post agendado não encontrado.'] }, status: :not_found
        end

        def retry
          post = ::ScheduledPost.find(params[:id])
          post.retry!
          render json: { success: true, data: post.as_json(only: post_fields) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Post agendado não encontrado.'] }, status: :not_found
        rescue RuntimeError => e
          render json: { success: false, errors: [e.message] }, status: :unprocessable_entity
        end

        private

        def post_fields
          %i[id caption platforms content_type status error_message external_post_ids scheduled_for retry_count max_retries created_at]
        end
      end
    end
  end
end
