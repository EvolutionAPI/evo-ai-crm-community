module GestorPosts
  # Marca como 'abandoned' lotes de carrossel que ficaram parados em
  # 'collecting' por mais de 1h (usuário fechou o modal no meio do upload dos
  # cards). Os containers já criados na Graph API expiram sozinhos do lado do
  # Meta; aqui só limpamos o registro local pra não ficar contado como
  # pendente pra sempre.
  class CarouselCleanupJob < ApplicationJob
    queue_as :low

    def perform
      CarouselUploadBatch.cleanup_abandoned!
    end
  end
end
