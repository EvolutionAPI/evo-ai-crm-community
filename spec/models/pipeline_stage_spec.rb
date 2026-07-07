# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineStage, 'stage_type enum' do
  let(:creador) { User.create!(name: 'Spec User', email: "spec-#{SecureRandom.hex(4)}@test.local") }
  let(:pipeline) { Pipeline.create!(name: "Enum #{SecureRandom.hex(4)}", created_by: creador) }

  it 'persiste el string enviado por el frontend en su valor de enum, no coercionado a 0' do
    stage = pipeline.pipeline_stages.create!(name: 'x', position: 1, stage_type: 'cancelled')
    expect(stage.reload.cancelled?).to be true
    expect(stage.read_attribute_before_type_cast(:stage_type)).to eq(2)
  end

  it 'mantiene active como default (compatible con filas preexistentes en 0)' do
    stage = pipeline.pipeline_stages.create!(name: 'y', position: 2)
    expect(stage.active?).to be true
  end

  it 'rechaza valores fuera del vocabulario del frontend' do
    expect do
      pipeline.pipeline_stages.new(name: 'z', position: 3, stage_type: 'archived')
    end.to raise_error(ArgumentError)
  end
end
