#!/usr/bin/env bash
# bin/deploy_vps.sh — safe deploy of this backend to the shared VPS.
#
# This repo is worked on from more than one machine (multiple Claude Code
# sessions). Building/deploying straight from a local checkout that hasn't
# pulled the other machine's already-merged work has silently overwritten
# production before: on 2026-09-04 a deploy from a stale local tree wiped
# two sidekiq-cron jobs (GestorPosts::CarouselCleanupJob,
# ScheduledPostsProcessorJob) that another machine had already shipped,
# because the deploying machine's local source simply didn't have them.
#
# This script refuses to build unless the current branch IS the deploy
# branch (default: main) AND its HEAD matches origin/<branch> exactly —
# i.e. it only ever ships code that is already merged and pushed on GitHub,
# never a machine-local working tree. That makes "whoever deploys last
# wins and quietly deletes the other's work" structurally impossible: any
# machine that deploys is always shipping the one shared history.
#
# Usage:
#   bin/deploy_vps.sh                 # deploy both web + sidekiq
#   bin/deploy_vps.sh crm             # web service only
#   bin/deploy_vps.sh sidekiq         # sidekiq service only
#   bin/deploy_vps.sh both my-note    # tag the image with a note
#
# Config (env vars, all optional):
#   DEPLOY_BRANCH   — branch that must be deployed from (default: main)
#   DEPLOY_SSH_KEY  — path to the VPS SSH key (default: ~/.ssh/id_ed25519_vps_crm)
#   DEPLOY_VPS_HOST — ssh target (default: root@145.223.26.168)
#   DEPLOY_REGISTRY — VPS-local docker registry (default: 127.0.0.1:5000)
set -euo pipefail
cd "$(dirname "$0")/.."

DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/id_ed25519_vps_crm}"
VPS_HOST="${DEPLOY_VPS_HOST:-root@145.223.26.168}"
REGISTRY="${DEPLOY_REGISTRY:-127.0.0.1:5000}"
IMAGE_NAME="evocrm-crm"
SERVICE_WEB="evocrm_evocrm_crm"
SERVICE_SIDEKIQ="evocrm_evocrm_crm_sidekiq"

TARGET="${1:-both}" # crm | sidekiq | both
NOTE="${2:-}"

ssh_vps() { ssh -i "$SSH_KEY" "$VPS_HOST" "$@" 2>&1 | grep -v "System is booting" || true; }

echo "==> Checking git state..."
if [ -n "$(git status --porcelain)" ]; then
  echo "ERRO: há mudanças não commitadas neste checkout." >&2
  echo "Commite e dê push antes de implantar (o deploy só sai do que já está no GitHub)." >&2
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$DEPLOY_BRANCH" ]; then
  echo "ERRO: você está na branch '$CURRENT_BRANCH', mas o deploy só roda a partir de '$DEPLOY_BRANCH'." >&2
  echo "Dê merge do seu trabalho em '$DEPLOY_BRANCH' primeiro, depois: git checkout $DEPLOY_BRANCH" >&2
  exit 1
fi

git fetch origin "$DEPLOY_BRANCH"
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/$DEPLOY_BRANCH")"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "ERRO: seu '$DEPLOY_BRANCH' local (${LOCAL_SHA:0:7}) está diferente do GitHub (${REMOTE_SHA:0:7})." >&2
  echo "Rode: git pull origin $DEPLOY_BRANCH   (ou git push, se seu commit ainda não foi enviado)." >&2
  echo "Isso existe justamente pra nunca implantar código que a outra máquina não viu." >&2
  exit 1
fi

echo "==> OK: implantando exatamente o commit ${LOCAL_SHA:0:7} de '$DEPLOY_BRANCH' (idêntico ao GitHub)."

TAG="deploy-$(date +%Y%m%d-%H%M)-${LOCAL_SHA:0:7}${NOTE:+-$NOTE}"
echo "==> Buildando $IMAGE_NAME:$TAG ..."
docker build --build-arg RAILS_ENV=production -t "$IMAGE_NAME:$TAG" -f docker/Dockerfile .

TARBALL_NAME="${IMAGE_NAME}-${TAG}.tar"
TARBALL_LOCAL="/tmp/$TARBALL_NAME"
docker save "$IMAGE_NAME:$TAG" -o "$TARBALL_LOCAL"

echo "==> Enviando pra VPS..."
scp -i "$SSH_KEY" "$TARBALL_LOCAL" "$VPS_HOST:/root/$TARBALL_NAME"
ssh_vps "docker load -i /root/$TARBALL_NAME && docker tag $IMAGE_NAME:$TAG $REGISTRY/$IMAGE_NAME:$TAG && docker push $REGISTRY/$IMAGE_NAME:$TAG && rm -f /root/$TARBALL_NAME"

deploy_service() {
  local service="$1"
  echo "==> Atualizando $service ..."
  ssh_vps "docker service update --image $REGISTRY/$IMAGE_NAME:$TAG --update-failure-action rollback --detach=false $service"
}

if [ "$TARGET" = "crm" ] || [ "$TARGET" = "both" ]; then
  deploy_service "$SERVICE_WEB"

  echo "==> Rodando migrações..."
  CID=""
  for _ in 1 2 3 4 5; do
    CID=$(ssh_vps "docker ps --format '{{.Names}}' | grep '^${SERVICE_WEB}\\.'" || true)
    [ -n "$CID" ] && break
    sleep 2
  done
  if [ -z "$CID" ]; then
    echo "AVISO: não achei o container do $SERVICE_WEB pra rodar migrações. Rode manualmente." >&2
  else
    ssh_vps "docker exec $CID bundle exec rails db:migrate"
  fi
fi

if [ "$TARGET" = "sidekiq" ] || [ "$TARGET" = "both" ]; then
  deploy_service "$SERVICE_SIDEKIQ"
fi

echo "==> Limpando..."
rm -f "$TARBALL_LOCAL"
ssh_vps "docker container prune -f; docker image prune -f"

echo "==> Pronto. $IMAGE_NAME:$TAG implantado a partir de $DEPLOY_BRANCH@${LOCAL_SHA:0:7}."
