# frozen_string_literal: true

require 'rails_helper'

# AC4: verifies that the 4 EvoFlow listeners are registered as global
# Wisper subscribers when the Rails app boots. The initializer runs
# `Wisper.subscribe(...)` inside `after_initialize`, so by the time the
# spec suite is loaded, the global listeners list must include them.
RSpec.describe 'EvoFlow listeners registration' do
  let(:registered_classes) do
    Wisper::GlobalListeners.send(:listeners).map(&:class)
  end

  %w[
    EvoFlow::ContactEventsListener
    EvoFlow::ConversationEventsListener
    EvoFlow::MessageEventsListener
    EvoFlow::PipelineEventsListener
  ].each do |klass_name|
    it "registers #{klass_name} as a global Wisper subscriber" do
      expect(registered_classes.map(&:name)).to include(klass_name)
    end
  end
end
