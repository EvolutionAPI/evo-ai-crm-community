namespace :integration_credentials do
  desc 'Simula a migração das credenciais de integração já cadastradas e imprime o relatório (não escreve nada)'
  task migrate_dry_run: :environment do
    rows = Ai::IntegrationCredentialMigration.call(apply: false)
    puts "Simulação concluída. #{rows.size} consumidor(es) conferido(s), nada foi escrito."
    puts 'Rode integration_credentials:migrate para aplicar.'
  rescue Ai::IntegrationCredentialMigration::AbortedError => e
    abort("Migração NÃO pode ser aplicada: #{e.message}")
  end

  desc 'Aplica a migração das credenciais de integração (aborta se algum consumidor mudaria de segredo efetivo)'
  task migrate: :environment do
    rows = Ai::IntegrationCredentialMigration.call(apply: true)
    puts "Migração aplicada. #{rows.size} consumidor(es) conferido(s), todos mantendo o segredo em uso."
  rescue Ai::IntegrationCredentialMigration::AbortedError => e
    abort("Migração abortada: #{e.message}")
  end
end
