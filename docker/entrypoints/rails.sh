#!/bin/sh

set -x

# Remove a potentially pre-existing server.pid for Rails.
rm -rf /app/tmp/pids/server.pid
rm -rf /app/tmp/cache/*

echo "Waiting for postgres to become ready...."

# Let DATABASE_URL env take presedence over individual connection params.
# This is done to avoid printing the DATABASE_URL in the logs
$(/app/docker/entrypoints/helpers/pg_database_url.rb)
PG_READY="pg_isready -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USERNAME"

until $PG_READY
do
  sleep 2;
done

echo "Database ready to accept connections."

# Ensure gems are installed and up-to-date
bundle check || bundle install

# Prepare the database (create if missing, run migrations).
# EVO-1999: RUN_MIGRATIONS gate (default 'true' = fail-safe) so the web service
# always migrates on boot, including on orchestrators that ignore the compose
# command/entrypoint (CapRover). Set RUN_MIGRATIONS=false on *-sidekiq services to
# avoid preparing the database twice (the web's db:prepare covers it, via advisory
# lock). Compared against "false" (not == "true") so TRUE/1/typos still migrate.
if [ "${RUN_MIGRATIONS:-true}" != "false" ]; then
  echo "Preparing database (RUN_MIGRATIONS=${RUN_MIGRATIONS:-true})..."
  # Fail-safe: abort the boot if db:prepare fails, instead of starting the server
  # against a stale/half-migrated schema. Lets the orchestrator restart and retry.
  bundle exec rails db:prepare || exit 1
else
  echo "Skipping database preparation (RUN_MIGRATIONS=${RUN_MIGRATIONS})."
fi

# Execute the main process of the container
exec "$@"
