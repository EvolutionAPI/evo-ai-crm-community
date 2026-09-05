# Atribuição de pedidos (vindos da Esteira de Pedidos — planilha própria +
# iFood, via webhook) a um motoboy cadastrado. Não referencia WorkOrder nem
# nenhum modelo de pedido local: a chave é (order_external_id, platform),
# o mesmo par que a Esteira usa pra identificar um card.
class Api::V1::Admin::MotoboyDeliveriesController < Api::V1::Admin::BaseController
  # GET /admin/motoboy_deliveries — entregas ativas (não entregues/canceladas),
  # pra Esteira/Logística saberem o que já está atribuído sem repetir atribuição.
  def index
    deliveries = MotoboyDelivery.where(status: %w[atribuido a_caminho]).includes(:motoboy)
    render json: { success: true, data: deliveries.map { |d| serialize(d) } }
  end

  # Atribui (ou reatribui, se já existir pra esse pedido) um motoboy a um pedido.
  def create
    delivery = MotoboyDelivery.find_or_initialize_by(
      order_external_id: params[:order_external_id].to_s,
      platform: params[:platform].presence || 'proprio'
    )
    delivery.assign_attributes(
      motoboy_id: params[:motoboy_id],
      customer_name: params[:customer_name],
      address: params[:address],
      status: 'atribuido',
      assigned_at: Time.current,
      delivered_at: nil
    )

    if delivery.save
      render json: { success: true, data: serialize(delivery) }, status: :created
    else
      render json: { success: false, message: delivery.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    delivery = MotoboyDelivery.find(params[:id])
    delivery.delivered_at = Time.current if params[:status] == 'entregue' && delivery.status != 'entregue'
    if delivery.update(delivery_params)
      render json: { success: true, data: serialize(delivery) }
    else
      render json: { success: false, message: delivery.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Entrega não encontrada' }, status: :not_found
  end

  def destroy
    delivery = MotoboyDelivery.find(params[:id])
    delivery.destroy!
    render json: { success: true, data: { id: delivery.id } }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Entrega não encontrada' }, status: :not_found
  end

  private

  def delivery_params
    params.permit(:motoboy_id, :status, :customer_name, :address)
  end

  def serialize(delivery)
    {
      id: delivery.id,
      motoboy_id: delivery.motoboy_id,
      motoboy_name: delivery.motoboy&.name,
      order_external_id: delivery.order_external_id,
      platform: delivery.platform,
      customer_name: delivery.customer_name,
      address: delivery.address,
      status: delivery.status,
      assigned_at: delivery.assigned_at&.iso8601,
      delivered_at: delivery.delivered_at&.iso8601
    }
  end
end
