# frozen_string_literal: true

# Anonymous, public digital-menu page — lists active products grouped by
# category. Inherits PublicController directly (like FormsController) so
# it's reachable without an API key: there's one catalog per instalação,
# no slug to resolve.
class Public::Api::V1::MenuController < PublicController
  # GET /public/api/v1/menu
  def show
    categories = ProductCategory.ordered.includes(:products)
    grouped = categories.filter_map do |category|
      products = category.products.active.sellable.order(:name)
      next if products.empty?

      { id: category.id, name: category.name, products: ProductMenuSerializer.serialize_collection(products) }
    end

    uncategorized = Product.active.sellable.where(category_id: nil).order(:name)
    grouped << { id: nil, name: 'Outros', products: ProductMenuSerializer.serialize_collection(uncategorized) } if uncategorized.any?

    render json: { success: true, data: { categories: grouped, settings: display_settings } }
  end

  private

  # Aparência configurável em Organização > Cardápio Digital, mais o número de
  # WhatsApp da loja — exposto para o botão "Abrir WhatsApp" da tela de
  # confirmação do pedido (o canal/inbox que efetivamente envia continua só
  # no backend, esse aqui é só o número público de contato).
  def display_settings
    {
      company_name: GlobalConfigService.load('MENU_COMPANY_NAME', nil),
      header_color: GlobalConfigService.load('MENU_HEADER_COLOR', nil),
      background_color: GlobalConfigService.load('MENU_BACKGROUND_COLOR', nil),
      footer_color: GlobalConfigService.load('MENU_FOOTER_COLOR', nil),
      icon_color: GlobalConfigService.load('MENU_ICON_COLOR', nil),
      text_color: GlobalConfigService.load('MENU_TEXT_COLOR', nil),
      title_color: GlobalConfigService.load('MENU_TITLE_COLOR', nil),
      company_name_color: GlobalConfigService.load('MENU_COMPANY_NAME_COLOR', nil),
      gtm_id: GlobalConfigService.load('MENU_GTM_ID', nil),
      whatsapp_number: GlobalConfigService.load('MENU_WHATSAPP_NUMBER', nil)
    }
  end
end
