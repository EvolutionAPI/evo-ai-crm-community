require 'rubocop'

# EVO-1551 round 6 — bans raw `.content_attributes` reads inside files that
# serialize messages to a client (REST serializers, jbuilder views, WS broadcast
# helpers, outbound webhook payload builders).
#
# Egress paths MUST go through `Message#content_attributes_for_egress(audience:)`
# so the PII masker is the single source of truth for every server boundary.
# Back-office paths (controllers, services, builders, jobs that read business
# keys like `moderation_id`) are NOT scoped by this cop and keep raw access.
#
# Configure scope via `Include` in .rubocop.yml — see the entry for this cop.
# The companion regression net is spec/regression/pii_egress_invariant_spec.rb.
class NoRawContentAttributesInEgress < RuboCop::Cop::Base
  MSG = 'Use `Message#content_attributes_for_egress(audience: :broadcast|:per_request)` ' \
        'instead of raw `.content_attributes` in egress paths. ' \
        'See EVO-1551 round 6.'.freeze

  # Match: receiver.content_attributes (no args, not an assignment).
  # The bare local-variable case `content_attributes` (NVAR) is ignored —
  # it only happens inside Message itself where the attribute is defined.
  def_node_matcher :raw_content_attributes_send?, <<~PATTERN
    (send !nil? :content_attributes)
  PATTERN

  # Match: receiver.attributes[:content_attributes] / ['content_attributes']
  # (the bug shape from EVO-1551 round 5, where push_event_data leaked via
  # `attributes.symbolize_keys`).
  def_node_matcher :attributes_hash_content_attributes?, <<~PATTERN
    (send (send _ {:attributes :symbolize_keys}) :[] {(sym :content_attributes) (str "content_attributes")})
  PATTERN

  def on_send(node)
    return unless raw_content_attributes_send?(node) || attributes_hash_content_attributes?(node)

    add_offense(node, message: MSG)
  end
end
