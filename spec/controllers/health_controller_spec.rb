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
    let(:body) { response.parsed_body }

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

      # `allow` + `have_received`, not a message expectation: constraining :error with
      # `with` would also fail this example on any UNRELATED error the request logs.
      it 'logs the underlying error instead of swallowing it' do
        allow(Rails.logger).to receive(:error)

        get :ready

        expect(Rails.logger).to have_received(:error)
          .with(/schema check failed.*permission denied/)
      end
    end

    # Regression guard for the bug that made the first version of this check useless:
    # the connection's default migration_context resolves to just ["db/migrate"], so it
    # never sees migrations appended by a mounted engine. Measured on a live boot, the
    # default context saw 79 migrations while the app's configured paths saw 216.
    it 'reads the application migration paths, not the connection default' do
      app_paths = %w[/app/db/migrate /enterprise/licensing-ruby/db/migrate]
      allow(Rails.application.paths['db/migrate']).to receive(:to_a).and_return(app_paths)
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(
        instance_double(ActiveRecord::MigrationContext, needs_migration?: false)
      )

      get :ready

      expect(response).to have_http_status(:ok)
      # Asserting on :new closes the whole link — that the configured paths are what the
      # context is BUILT from. Asserting only that `to_a` was called would still pass if
      # the result were read and then discarded.
      expect(ActiveRecord::MigrationContext).to have_received(:new).with(app_paths)
    end
  end

  def stub_migration_context(needs_migration:)
    allow(ActiveRecord::MigrationContext).to receive(:new).and_return(
      instance_double(ActiveRecord::MigrationContext, needs_migration?: needs_migration)
    )
  end
end
