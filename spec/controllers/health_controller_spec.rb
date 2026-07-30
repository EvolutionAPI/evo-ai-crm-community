require 'rails_helper'

# `/health/ready` gates the whole compose boot: the enterprise healthcheck points at it
# and six services block on `enterprise: service_healthy`. A regression here does not
# fail loudly — it reports green over an incomplete schema, which is the exact failure
# this endpoint was added to remove (EVO-2252).
RSpec.describe HealthController, type: :controller do
  before do
    allow(controller).to receive(:check_database).and_return(true)
    allow(controller).to receive(:check_redis).and_return(true)
  end

  describe 'GET #ready' do
    let(:body) { JSON.parse(response.body) }

    context 'when the schema is up to date' do
      before { stub_migration_context(needs_migration: false) }

      it 'reports ready' do
        get :ready

        expect(response).to have_http_status(:ok)
        expect(body['ready']).to be(true)
        expect(body.dig('checks', 'schema')).to eq('ok')
      end
    end

    context 'when a migration is pending' do
      before { stub_migration_context(needs_migration: true) }

      it 'reports NOT ready with 503' do
        get :ready

        expect(response).to have_http_status(:service_unavailable)
        expect(body['ready']).to be(false)
        expect(body.dig('checks', 'schema')).to eq('pending_migrations')
      end
    end

    # A check that cannot RUN is a different failure from a schema that is BEHIND.
    # Reporting a permission error as "pending_migrations" would send whoever reads it
    # to run migrations that are already applied.
    context 'when the schema check itself raises' do
      before do
        allow(ActiveRecord::MigrationContext).to receive(:new)
          .and_raise(StandardError, 'permission denied for table schema_migrations')
      end

      it 'reports check_failed, not pending_migrations' do
        get :ready

        expect(response).to have_http_status(:service_unavailable)
        expect(body.dig('checks', 'schema')).to eq('check_failed')
      end

      it 'logs the underlying error instead of swallowing it' do
        expect(Rails.logger).to receive(:error).with(/schema check failed.*permission denied/)

        get :ready
      end
    end

    # Regression guard for the bug that made the first version of this check useless:
    # the connection's default migration_context resolves to just ["db/migrate"], so it
    # never sees migrations appended by a mounted engine. Measured on a live boot, the
    # default context saw 79 migrations while the app's configured paths saw 216.
    it 'reads the application migration paths, not the connection default' do
      expect(Rails.application.paths['db/migrate']).to receive(:to_a).and_return(%w[db/migrate])
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(
        instance_double(ActiveRecord::MigrationContext, needs_migration?: false)
      )

      get :ready

      expect(response).to have_http_status(:ok)
    end
  end

  def stub_migration_context(needs_migration:)
    allow(ActiveRecord::MigrationContext).to receive(:new).and_return(
      instance_double(ActiveRecord::MigrationContext, needs_migration?: needs_migration)
    )
  end
end
