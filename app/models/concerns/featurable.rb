module Featurable
  extend ActiveSupport::Concern

  QUERY_MODE = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze

  FEATURES = FEATURE_LIST.each_with_object({}) do |feature, result|
    result[result.keys.size + 1] = "feature_#{feature['name']}".to_sym
  end

  included do
    include FlagShihTzu
    has_flags FEATURES.merge(column: 'feature_flags').merge(QUERY_MODE)

    before_create :enable_default_features
  end

  def enable_features(*names)
    names.each do |name|
      send("feature_#{name}=", true)
    end
  end

  def enable_features!(*)
    enable_features(*)
    save!
  end

  def disable_features(*names)
    names.each do |name|
      send("feature_#{name}=", false)
    end
  end

  def disable_features!(*)
    disable_features(*)
    save!
  end

  def feature_enabled?(name)
    send("feature_#{name}?")
  end

  def all_features
    FEATURE_LIST.pluck('name').index_with do |feature_name|
      feature_enabled?(feature_name)
    end
  end

  def enabled_features
    all_features.select { |_feature, enabled| enabled == true }
  end

  def disabled_features
    all_features.select { |_feature, enabled| enabled == false }
  end

  private

  def enable_default_features
    features_to_enabled = account_level_feature_defaults.select { |f| f[:enabled] }.pluck(:name)
    enable_features(*features_to_enabled) if features_to_enabled.present?
    true
  end

  # EVO-2000: fonte das features default. Primária é o InstallationConfig
  # 'ACCOUNT_LEVEL_FEATURE_DEFAULTS' (populado pelo ConfigLoader no seed). Se ele
  # não existir (seed não rodou/instalação incompleta), cai para o config/features.yml
  # — a MESMA fonte que o ConfigLoader usa — para a conta nunca nascer sem features.
  def account_level_feature_defaults
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return config.value if config.present?

    default_features_from_file
  end

  def default_features_from_file
    path = Rails.root.join('config', 'features.yml')
    return [] unless File.exist?(path)

    YAML.safe_load_file(path).map(&:with_indifferent_access)
  rescue StandardError => e
    Rails.logger.error("[EVO-2000] fallback de features (features.yml) falhou: #{e.message}")
    []
  end
end
