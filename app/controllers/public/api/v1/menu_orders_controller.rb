# frozen_string_literal: true

# Anonymous, public order submission from the digital menu checkout — enqueues
# DigitalMenu::SendOrderNotificationJob to deliver the order to the store's
# WhatsApp using whatever channel/number is configured in Organização >
# Cardápio Digital. Always 200s immediately for the customer: the actual send
# runs in background, so neither a slow/hanging provider call nor a missing
# configuration ever blocks the checkout response. The response carries an
# `order_token` the frontend polls via #status to know if the background send
# actually succeeded — used to show a "send it yourself via WhatsApp" fallback
# (with the order pre-filled) only when the automated send really failed.
class Public::Api::V1::MenuOrdersController < PublicController
  def create
    order_token = params[:order_token].presence || SecureRandom.uuid
    Redis::Alfred.setex("digital_menu_order_status:#{order_token}", 'pending', DigitalMenu::SendOrderNotificationJob::STATUS_TTL)

    DigitalMenu::SendOrderNotificationJob.perform_later(
      order_token: order_token,
      customer: customer_params,
      items: items_params,
      payment_method: params[:payment_method].to_s,
      notes: params[:notes].to_s
    )

    render json: { success: true, order_token: order_token }
  end

  # GET /public/api/v1/menu/orders/:token/status
  def status
    status = Redis::Alfred.get("digital_menu_order_status:#{params[:token]}") || 'pending'
    render json: { success: true, status: status }
  end

  private

  def customer_params
    params.require(:customer)
          .permit(:full_name, :cpf, :birth_date, :gender, :phone, :instagram, :email,
                   :zip, :address, :number, :neighborhood, :city, :state)
          .to_h.symbolize_keys
  end

  def items_params
    params.require(:items).map do |item|
      item.permit(:name, :price, :quantity).to_h.symbolize_keys
    end
  end
end
