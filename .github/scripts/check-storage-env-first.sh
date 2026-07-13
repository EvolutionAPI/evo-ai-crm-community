#!/usr/bin/env bash
#
# EVO-2095 — storage service + credentials must resolve from the ENV, never from
# the DB (GlobalConfigService.load, which is DB-over-ENV). Reading the DB during
# boot config also fires the active_storage_blob load hook before the service is
# assigned, freezing it as DiskService in some processes -> attachments land on
# the container's ephemeral disk and vanish on redeploy.
#
# Source guard (no Rails/DB). Runs in the repo CI; also usable with fixtures:
#   check-storage-env-first.sh [PRODUCTION_RB] [STORAGE_YML]

prod="${1:-config/environments/production.rb}"
storage="${2:-config/storage.yml}"
fail=0

# 1) production.rb: active_storage.service resolved from the ENV, not GlobalConfigService.
svc="$(grep -E 'config\.active_storage\.service' "$prod" 2>/dev/null | grep -vE '^[[:space:]]*#' | head -1)"
if ! printf '%s' "$svc" | grep -q "ENV.fetch('ACTIVE_STORAGE_SERVICE'"; then
  echo "::error::$prod: active_storage.service must resolve from ENV.fetch('ACTIVE_STORAGE_SERVICE', ...)"
  fail=1
fi
if printf '%s' "$svc" | grep -q 'GlobalConfigService'; then
  echo "::error::$prod: active_storage.service must NOT use GlobalConfigService (DB-over-ENV at boot -> ephemeral disk)"
  fail=1
fi

# 2) storage.yml: s3_compatible credentials ENV-first (load_env_first), never DB-first (.load().
if ! grep -q 'load_env_first' "$storage" 2>/dev/null; then
  echo "::error::$storage: s3_compatible credentials must use GlobalConfigService.load_env_first (ENV-first)"
  fail=1
fi
if grep -qE 'GlobalConfigService\.load\(' "$storage" 2>/dev/null; then
  echo "::error::$storage: must NOT use GlobalConfigService.load( for storage credentials (DB-first)"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: storage service + credentials resolve ENV-first (EVO-2095)."
fi
exit "$fail"
