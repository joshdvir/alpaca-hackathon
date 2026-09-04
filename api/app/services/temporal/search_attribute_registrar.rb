# frozen_string_literal: true

# Temporal::SearchAttributeRegistrar — idempotently register the project's
# custom search attributes with the Temporal namespace.
#
# Without this, any visibility query that references a non-system attribute
# (e.g. `WorkflowKind = 'process_ticker'`) fails with
# "invalid query: column name 'WorkflowKind' is not a valid search attribute".
#
# Temporal's `add_search_attributes` is an additive idempotent operation:
# adding an attribute that already exists is a no-op (the operator service
# returns success). We still read the current attribute list first to avoid
# generating noise in the log and to make the result a clear diff.
#
# Usage:
#   Temporal::SearchAttributeRegistrar.new.ensure!  # idempotent
#   Temporal::SearchAttributeRegistrar.new(client: fake).ensure!

module Temporal
  class SearchAttributeRegistrar
    # The custom attributes this app requires.
    # Keys are search-attribute names; values are Temporal IndexedValueType
    # enum values. Keep in sync with config/initializers/temporal.rb
    # (TickerKey / WorkflowKindKey).
    REQUIRED_ATTRIBUTES = {
      'Ticker'       => Temporalio::SearchAttributes::IndexedValueType::KEYWORD,
      'WorkflowKind' => Temporalio::SearchAttributes::IndexedValueType::KEYWORD
    }.freeze

    def initialize(client: T_CLIENT, namespace: TEMPORAL_NAMESPACE, logger: Rails.logger)
      @client    = client
      @namespace = namespace
      @logger    = logger
    end

    # Returns the list of attribute names that were added in this call.
    # Attributes that already existed are left alone.
    def ensure!
      existing = list_custom_attribute_names
      missing  = REQUIRED_ATTRIBUTES.reject { |name, _type| existing.include?(name) }

      if missing.empty?
        @logger.info "[temporal:search_attributes] all #{REQUIRED_ATTRIBUTES.size} custom attributes already registered"
        return []
      end

      request = build_add_request(missing)
      @client.connection.operator_service.add_search_attributes(request)
      @logger.info "[temporal:search_attributes] added: #{missing.keys.sort.join(', ')}"
      missing.keys
    end

    # Returns the current set of custom attribute names registered on the
    # namespace. Useful for tests and ops.
    def list_custom_attribute_names
      response = @client.connection.operator_service.list_search_attributes(
        Temporalio::Api::OperatorService::V1::ListSearchAttributesRequest.new(namespace: @namespace)
      )
      response.custom_attributes.keys.to_set
    end

    private

    def build_add_request(attrs_by_name)
      # The proto is a Map<string, IndexedValueType>. The SDK protobuf
      # accepts a plain Ruby Hash and serializes the value as the enum
      # integer automatically.
      Temporalio::Api::OperatorService::V1::AddSearchAttributesRequest.new(
        namespace: @namespace,
        search_attributes: attrs_by_name
      )
    end
  end
end
