# frozen_string_literal: true

# Smoke-load the public extension contract so the host application crashes
# loud at boot if the entry point is broken. No overrides are registered
# here — community ships with no-op defaults. See lib/evo_extension_points.rb
# and EXTENSION_POINTS.md at the repo root.
require 'evo_extension_points'

Rails.application.config.after_initialize do
  EvoExtensionPoints::PluginLoader.load_all
end
