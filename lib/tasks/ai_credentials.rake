namespace :ai_credentials do
  desc 'Simula a migração das credenciais de IA já cadastradas e imprime o relatório (não escreve nada)'
  task migrate_dry_run: :environment do
    Ai::CredentialMigration.call(apply: false)
    puts 'Simulação concluída. Nada foi escrito. Rode ai_credentials:migrate para aplicar.'
  rescue Ai::CredentialMigration::AbortedError => e
    abort("Migração NÃO pode ser aplicada: #{e.message}")
  end

  desc 'Aplica a migração das credenciais de IA (aborta se alguma conta mudaria de credencial efetiva)'
  task migrate: :environment do
    rows = Ai::CredentialMigration.call(apply: true)
    puts "Migração aplicada. #{rows.size} linha(s) conferida(s), todas mantendo a credencial em uso."
  rescue Ai::CredentialMigration::AbortedError => e
    abort("Migração abortada: #{e.message}")
  end
end
