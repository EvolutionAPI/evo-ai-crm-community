# Cadastro dos motoboys próprios do estabelecimento (não é o marketplace de
# entregadores do iFood/99 — ver Ifood::Client#request_driver e
# NinetyNine::Client pra isso). Usado pela Logística de Motoboys, dentro de
# Ordens.
class Api::V1::Admin::MotoboysController < Api::V1::Admin::BaseController
  def index
    motoboys = Motoboy.active_only.order(:name)
    render json: { success: true, data: motoboys.map { |m| serialize(m) } }
  end

  def create
    motoboy = Motoboy.new(motoboy_params)
    if motoboy.save
      render json: { success: true, data: serialize(motoboy) }, status: :created
    else
      render json: { success: false, message: motoboy.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    motoboy = Motoboy.find(params[:id])
    if motoboy.update(motoboy_params)
      render json: { success: true, data: serialize(motoboy) }
    else
      render json: { success: false, message: motoboy.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Motoboy não encontrado' }, status: :not_found
  end

  # Soft-delete: mantém o histórico de entregas (motoboy_deliveries) intacto.
  def destroy
    motoboy = Motoboy.find(params[:id])
    motoboy.update!(active: false)
    render json: { success: true, data: serialize(motoboy) }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Motoboy não encontrado' }, status: :not_found
  end

  private

  def motoboy_params
    params.permit(:name, :phone, :vehicle_type, :status, :notes)
  end

  def serialize(motoboy)
    {
      id: motoboy.id,
      name: motoboy.name,
      phone: motoboy.phone,
      vehicle_type: motoboy.vehicle_type,
      status: motoboy.status,
      notes: motoboy.notes,
      active_deliveries_count: motoboy.motoboy_deliveries.where(status: %w[atribuido a_caminho]).count
    }
  end
end
