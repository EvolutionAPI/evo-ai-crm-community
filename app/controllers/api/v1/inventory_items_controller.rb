module Api
  module V1
    class InventoryItemsController < Api::V1::BaseController
      before_action :fetch_inventory_item, only: [:show, :update, :destroy]

      def index
        @items = InventoryItem.order(:name)
        render json: { success: true, data: @items }
      end

      def show
        render json: { success: true, data: @item }
      end

      def create
        @item = InventoryItem.new(inventory_item_params)
        if @item.save
          render json: { success: true, data: @item }, status: :created
        else
          render json: { success: false, errors: @item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @item.update(inventory_item_params)
          render json: { success: true, data: @item }
        else
          render json: { success: false, errors: @item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @item.destroy
        render json: { success: true, message: 'Item deleted successfully' }
      end

      private

      def fetch_inventory_item
        @item = InventoryItem.find(params[:id])
      end

      def inventory_item_params
        params.require(:inventory_item).permit(:name, :sku, :unit, :quantity, :min_quantity)
      end
    end
  end
end
