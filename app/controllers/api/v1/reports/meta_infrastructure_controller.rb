# Despacha os 15 passos do "Setup de Infraestrutura Meta" (Meta::InfrastructureService)
# por `acao`, mesmo estilo do Api::V1::Reports::MetaAdsManagerController — o
# front manda { acao, ...campos } e recebe a resposta real da Graph API.
class Api::V1::Reports::MetaInfrastructureController < Api::V1::BaseController
  def handle
    service = Meta::InfrastructureService.new

    case params[:acao]
    when 'lista_bms'
      respond(Meta::AdsManagerService.new.business_managers)
    when 'criar_conta_anuncio'
      respond(service.create_ad_account(
        business_id: params.require(:business_id),
        name: params.require(:name),
        currency: params.require(:currency),
        timezone_id: params[:timezone_id].presence || '1'
      ))
    when 'criar_dataset'
      respond(service.create_dataset(business_id: params.require(:business_id), name: params.require(:name)))
    when 'configurar_dataset'
      respond(service.configure_dataset(dataset_id: params.require(:dataset_id)))
    when 'vincular_dataset_conta'
      respond(service.link_dataset_to_account(
        dataset_id: params.require(:dataset_id),
        ad_account_id: params.require(:ad_account_id),
        business_id: params.require(:business_id)
      ))
    when 'associar_dominio'
      respond(service.associate_domain(business_id: params.require(:business_id), domain: params.require(:domain)))
    when 'conectar_instagram_pagina'
      respond(service.connect_instagram_to_page(
        page_id: params.require(:page_id),
        instagram_account_id: params.require(:instagram_account_id)
      ))
    when 'vincular_pagina_conta'
      respond(service.link_page_to_ad_account(
        business_id: params.require(:business_id),
        page_id: params.require(:page_id),
        ad_account_id: params.require(:ad_account_id)
      ))
    when 'vincular_whatsapp_conta'
      respond(service.link_whatsapp_to_ad_account(
        ad_account_id: params.require(:ad_account_id),
        waba_id: params.require(:waba_id),
        page_id: params.require(:page_id),
        phone_number_id: params.require(:phone_number_id)
      ))
    when 'criar_pasta_criativos'
      respond(service.create_creative_folder(ad_account_id: params.require(:ad_account_id), name: params.require(:name)))
    when 'salvar_nomenclaturas'
      respond(service.save_naming_conventions(
        campaign: params[:campaign], adset: params[:adset], ad: params[:ad], utm: params[:utm]
      ))
    when 'inscrever_webhook_leads'
      respond(service.subscribe_leads_webhook(page_id: params.require(:page_id)))
    when 'registrar_numero_whatsapp'
      respond(service.register_whatsapp_number(phone_number_id: params.require(:phone_number_id), pin: params[:pin]))
    when 'checar_qualidade_eventos'
      respond(service.check_event_quality(dataset_id: params.require(:dataset_id)))
    when 'conceder_acesso_parceiro'
      respond(service.grant_partner_access(
        ad_account_id: params.require(:ad_account_id),
        business_id: params.require(:business_id),
        partner_business_id: params.require(:partner_business_id)
      ))
    when 'aceitar_termos_lead_ads'
      respond(service.accept_lead_ads_tos(page_id: params.require(:page_id), business_id: params.require(:business_id)))
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: result.data
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end
end
