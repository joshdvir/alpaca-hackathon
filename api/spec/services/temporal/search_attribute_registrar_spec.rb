# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Temporal::SearchAttributeRegistrar do # rubocop:disable Metrics/BlockLength
  # Stand-in for the Temporal client. We stub the connection-level
  # operator_service the service actually uses, without needing a live
  # Temporal server.
  let(:fake_connection) { instance_double(Temporalio::Client::Connection) }
  let(:fake_op_service) { instance_double(Temporalio::Client::Connection::OperatorService) }
  let(:fake_client)     { instance_double(Temporalio::Client, connection: fake_connection) }
  let(:fake_logger)     { instance_double(Logger, info: nil, warn: nil) }
  let(:registrar) do
    described_class.new(client: fake_client, namespace: 'default', logger: fake_logger)
  end

  def list_response_with(*names)
    # Protobuf-generated message classes expose fields via reflection,
    # not as Ruby instance methods, so instance_double cannot verify them.
    # A plain double is the right tool here.
    resp = double('ListSearchAttributesResponse')
    allow(resp).to receive(:custom_attributes).and_return(
      names.each_with_object({}) { |n, h| h[n] = :KEYWORD }
    )
    resp
  end

  describe '#list_custom_attribute_names' do
    it 'returns the set of custom attribute names from the operator service' do
      allow(fake_op_service).to receive(:list_search_attributes)
        .with(an_instance_of(Temporalio::Api::OperatorService::V1::ListSearchAttributesRequest))
        .and_return(list_response_with('Ticker', 'WorkflowKind', 'OtherThing'))
      allow(fake_connection).to receive(:operator_service).and_return(fake_op_service)

      expect(registrar.list_custom_attribute_names).to eq(%w[Ticker WorkflowKind OtherThing].to_set)
    end
  end

  describe '#ensure!' do
    before do
      allow(fake_connection).to receive(:operator_service).and_return(fake_op_service)
    end

    it 'is a no-op when all required attributes are already registered' do
      allow(fake_op_service).to receive(:list_search_attributes)
        .and_return(list_response_with('Ticker', 'WorkflowKind'))
      expect(fake_op_service).not_to receive(:add_search_attributes)

      result = registrar.ensure!
      expect(result).to eq([])
    end

    it 'adds missing attributes and returns their names' do
      allow(fake_op_service).to receive(:list_search_attributes)
        .and_return(list_response_with('Ticker')) # WorkflowKind missing
      expect(fake_op_service).to receive(:add_search_attributes) do |req|
        expect(req).to be_a(Temporalio::Api::OperatorService::V1::AddSearchAttributesRequest)
        expect(req.namespace).to eq('default')
        # Only WorkflowKind in the add request
        expect(req.search_attributes.keys).to eq(['WorkflowKind'])
        double('AddSearchAttributesResponse')
      end

      result = registrar.ensure!
      expect(result).to eq(['WorkflowKind'])
    end

    it 'adds all attributes when none are registered' do
      allow(fake_op_service).to receive(:list_search_attributes)
        .and_return(list_response_with)
      expect(fake_op_service).to receive(:add_search_attributes) do |req|
        expect(req.search_attributes.keys).to match_array(%w[Ticker WorkflowKind])
        double('AddSearchAttributesResponse')
      end

      result = registrar.ensure!
      expect(result).to match_array(%w[Ticker WorkflowKind])
    end
  end
end
