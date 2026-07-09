# frozen_string_literal: true

require 'rails_helper'

# Conformance guard: every permission key wired into a controller through
# require_permission(s) must exist in the auth RBAC catalog. The per-controller
# *_rbac_spec files stub check_user_permission against literal lists, so an
# off-catalog key (a typo, or an action the auth service never defined) would
# pass those specs yet deny every real user at runtime. This spec reflects over
# the concern's registry of declared keys and asserts each is a valid catalog
# key, using the in-repo catalog mirror as the notion of the catalog (the SSOT
# lives in the sibling auth repo). When that sibling is checked out alongside
# this repo, the mirror is additionally cross-checked against it for drift.
RSpec.describe 'require_permissions catalog conformance' do
  CATALOG_MIRROR_PATH = Rails.root.join('spec/fixtures/rbac/permission_catalog.yml')
  SIBLING_CATALOG_PATH =
    Rails.root.join('..', 'evo-auth-service-community', 'app', 'models', 'resource_actions_config.rb')

  # Pre-existing keys wired in controllers that the auth catalog does not
  # define — real conformance gaps surfaced by this guard, kept visible as
  # DEBT instead of silently passing. Closing any of these requires ADDING the
  # resource/action to the auth catalog SSOT (escalated to a human); they are
  # not typos of an existing key. Shrink this list, never grow it: a NEW
  # off-catalog key fails the conformance example below.
  #   dashboard.read        -> DashboardController#customer (no `dashboard`
  #                            resource in the catalog)
  # reports.create/update/delete left this list when EVO-2070 deleted the api/v2
  # ReportsController that declared them: the debt was closed by removing the
  # unreachable gate, not by adding the actions to the catalog.
  KNOWN_OFF_CATALOG_KEYS = %w[
    dashboard.read
  ].to_set

  def catalog_keys
    @catalog_keys ||= YAML.safe_load_file(CATALOG_MIRROR_PATH).to_set
  end

  def declared_keys
    # Controllers register their keys at class-load time; force everything to
    # load so the registry is complete regardless of test-run selection.
    Rails.application.eager_load!
    EvoPermissionConcern.declared_permission_keys
  end

  it 'declares at least one gated permission key (registry is wired)' do
    expect(declared_keys).not_to be_empty
  end

  it 'gates only keys that exist in the auth catalog (or are known debt)' do
    off_catalog = declared_keys.reject do |key|
      catalog_keys.include?(key) || KNOWN_OFF_CATALOG_KEYS.include?(key)
    end

    expect(off_catalog).to be_empty,
      "require_permissions references keys absent from the auth catalog: #{off_catalog.sort.join(', ')}"
  end

  it 'keeps the off-catalog debt list honest (entries still declared and still off-catalog)' do
    stale = KNOWN_OFF_CATALOG_KEYS.select do |key|
      !declared_keys.include?(key) || catalog_keys.include?(key)
    end

    expect(stale).to be_empty,
      "KNOWN_OFF_CATALOG_KEYS entries no longer apply (remove them): #{stale.to_a.sort.join(', ')}"
  end

  it 'keeps the catalog mirror in sync with the auth SSOT when it is available' do
    skip 'sibling evo-auth-service-community not checked out' unless File.exist?(SIBLING_CATALOG_PATH)

    load SIBLING_CATALOG_PATH
    ssot_keys = ResourceActionsConfig.all_permission_keys.to_set

    expect(catalog_keys).to eq(ssot_keys),
      'spec/fixtures/rbac/permission_catalog.yml has drifted from the auth ' \
      'ResourceActionsConfig catalog; regenerate it from the sibling repo.'
  end
end
