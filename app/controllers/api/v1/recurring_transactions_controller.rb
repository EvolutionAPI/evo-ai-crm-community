# frozen_string_literal: true

module Api
  module V1
    class RecurringTransactionsController < Api::V1::BaseController
      before_action :fetch_recurrence, only: [:update, :destroy]

      def index
        RecurringTransaction.materialize_all!
        @recurrences = RecurringTransaction.order(active: :desc, created_at: :desc)
        render json: { success: true, data: RecurringTransactionSerializer.serialize_collection(@recurrences) }
      end

      def create
        @recurrence = RecurringTransaction.new(recurrence_params)
        if @recurrence.save
          @recurrence.generate_occurrences!
          render json: { success: true, data: serialize_recurrence(@recurrence.reload) }, status: :created
        else
          render json: { success: false, errors: @recurrence.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @recurrence.update(recurrence_params)
          @recurrence.regenerate_future!
          render json: { success: true, data: serialize_recurrence(@recurrence.reload) }
        else
          render json: { success: false, errors: @recurrence.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        if params[:delete_future] == 'true'
          @recurrence.financial_transactions.where('transaction_date > ?', Time.current).destroy_all
        end
        @recurrence.destroy
        render json: { success: true, message: 'Recorrência excluída com sucesso' }
      end

      private

      def fetch_recurrence
        @recurrence = RecurringTransaction.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Recorrência não encontrada'] }, status: :not_found
      end

      def recurrence_params
        params.require(:recurring_transaction).permit(
          :kind, :scope, :description, :category, :amount,
          :start_date, :frequency, :interval_days,
          :end_rule, :end_date, :max_occurrences, :active
        )
      end

      def serialize_recurrence(recurrence)
        RecurringTransactionSerializer.serialize(recurrence)
      end
    end
  end
end
