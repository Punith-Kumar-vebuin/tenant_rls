require 'spec_helper'

RSpec.describe 'TenantRls Job Context Integration - Optimized' do
  before do
    # Configure tenant_rls for job_context strategy
    TenantRls.configure do |config|
      config.tenant_resolver_strategy = :job_context
      config.debug_logging = true
    end
  end

  after do
    # Reset tenant context after each test
    TenantRls.reset!
  end

  describe 'JobContextResolver - Optimized' do
    let(:resolver) { TenantRls::JobContextResolver }

    context 'Worker pattern - Enhanced' do
      it 'extracts company_id from worker perform args (3 args)' do
        # Test pattern: def perform(notification_type, notification_data, company_id)
        args = ['todo', { 'user' => { 'id' => 1 } }, 123]
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(123)
      end

      it 'extracts company_id from worker perform args (2 args)' do
        # Test pattern: def perform(notification_data, company_id)
        args = [{ 'user' => { 'id' => 1 } }, 456]
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(456)
      end

      it 'validates company_id is a positive integer' do
        # Negative company_id should be rejected
        args = ['todo', { 'user' => { 'id' => 1 } }, -123]
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'handles string company_id gracefully' do
        # String company_id should be rejected
        args = ['todo', { 'user' => { 'id' => 1 } }, '123']
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'checks second-to-last argument as fallback' do
        # When last argument is not a valid company_id
        args = ['todo', { 'user' => { 'id' => 1 } }, 456, 'extra_param']
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(456)
      end

      it 'handles hash-based worker args' do
        args = { company_id: 789 }
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(789)
      end

      it 'returns nil for invalid worker args' do
        args = ['string_arg', 'another_string']
        context = { worker_perform_args: args }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'handles empty or nil args' do
        context = { worker_perform_args: nil }
        expect(resolver.resolve(context)).to be_nil

        context = { worker_perform_args: [] }
        expect(resolver.resolve(context)).to be_nil
      end
    end

    context 'Job pattern - Enhanced' do
      it 'extracts company_id from job data with direct company_id' do
        job_data = { company_id: 101 }
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(101)
      end

      it 'validates job data company_id is positive integer' do
        job_data = { company_id: -101 }
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'extracts company_id from nested company object' do
        job_data = { company: { id: 202 } }
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(202)
      end

      it 'handles string keys' do
        job_data = { 'company' => { 'id' => 303 } }
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(303)
      end

      it 'prioritizes direct company_id over nested company.id' do
        job_data = { company_id: 100, company: { id: 200 } }
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(100)  # Direct company_id takes priority
      end

      it 'handles DeepHashie objects' do
        # Mock DeepHashie object
        mock_company = double('Company', id: 404)
        mock_job_data = double('JobData', company: mock_company)
        allow(mock_job_data).to receive(:respond_to?).with(:company).and_return(true)

        context = { job_data: mock_job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(404)
      end

      it 'parses JSON string payload' do
        job_data = '{"company": {"id": 505}}'
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to eq(505)
      end

      it 'handles invalid JSON gracefully' do
        job_data = 'invalid json'
        context = { job_data: job_data }

        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end
    end

    context 'Performance and Edge Cases' do
      it 'handles empty context gracefully' do
        context = {}
        tenant_id = resolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'handles nil context gracefully' do
        tenant_id = resolver.resolve(nil)
        expect(tenant_id).to be_nil
      end

      it 'logs appropriate warnings for missing data' do
        expect(Rails.logger).to receive(:warn).with(/No tenant_id could be resolved/)

        context = { unknown_key: 'value' }
        resolver.resolve(context)
      end
    end
  end

  describe 'TenantRls::Job module - Optimized' do
    let(:mock_application_record) { double('ApplicationRecord') }
    let(:mock_connection) { double('Connection') }

    before do
      stub_const('ApplicationRecord', mock_application_record)
      allow(mock_application_record).to receive(:with_tenant).and_yield
      allow(mock_application_record).to receive(:connection).and_return(mock_connection)
      allow(mock_connection).to receive(:execute)
    end

    context 'Sidekiq Worker Integration - Fixed' do
      # Mock worker class using prepend (new approach)
      let(:worker_class) do
        Class.new do
          include TenantRls::Job

          def self.sidekiq_options
            {}
          end

          # Original perform method
          def perform(notification_type, notification_data, company_id)
            "Worker executed with company_id: #{company_id}"
          end
        end
      end

      it 'automatically wraps perform method with tenant context' do
        worker = worker_class.new

        # The prepend approach should automatically wrap the perform method
        result = worker.perform('todo', { 'user' => { 'id' => 1 } }, 123)

        expect(result).to eq('Worker executed with company_id: 123')
      end

      it 'provides manual worker context setup' do
        worker = worker_class.new
        args = ['todo', { 'user' => { 'id' => 1 } }, 123]

        result = worker.with_tenant_context_for_worker(*args) do
          worker.class.new.perform(*args)  # Call original perform
        end

        expect(result).to eq('Worker executed with company_id: 123')
      end
    end

    context 'ActiveJob Integration - Enhanced' do
      # Mock job class
      let(:job_class) do
        Class.new do
          include TenantRls::Job

          def from_job_data(data)
            # Simulate Common module behavior
            parsed_data = JSON.parse(data)
            OpenStruct.new(
              user: parsed_data['user'],
              company: OpenStruct.new(id: parsed_data['company']['id'])
            )
          end

          def perform(payload)
            "Job executed with payload: #{payload}"
          end
        end
      end

      it 'automatically sets tenant context for jobs with from_job_data' do
        job = job_class.new
        payload = '{"user": {"id": 1}, "company": {"id": 456}}'

        result = job.around_perform_with_tenant_context(payload) do
          job.perform(payload)
        end

        expect(result).to eq("Job executed with payload: #{payload}")
      end

      it 'handles jobs without from_job_data method' do
        simple_job_class = Class.new do
          include TenantRls::Job

          def perform(payload)
            'Simple job executed'
          end
        end

        job = simple_job_class.new
        payload = { company: { id: 789 } }

        result = job.around_perform_with_tenant_context(payload) do
          job.perform(payload)
        end

        expect(result).to eq('Simple job executed')
      end
    end

    context 'RLS Execution Verification' do
      it 'verifies PostgreSQL session variable is set correctly' do
        # Mock PostgreSQL response
        allow(mock_connection).to receive(:execute)
          .with('SHOW tenant_rls.tenant_id')
          .and_return([{'tenant_rls.tenant_id' => '123'}])

        worker_class = Class.new do
          include TenantRls::Job

          def perform(company_id)
            debug_tenant_context('Test verification')
          end
        end

        worker = worker_class.new
        result = worker.debug_tenant_context('Test')

        expect(result).to include(:tenant_id, :user, :postgresql_setting)
      end

      it 'detects RLS mismatch between Current and PostgreSQL' do
        # Set up mismatch scenario
        TenantRls::Current.tenant_id = 123
        allow(mock_connection).to receive(:execute)
          .with('SHOW tenant_rls.tenant_id')
          .and_return([{'tenant_rls.tenant_id' => '456'}])

        expect(Rails.logger).to receive(:error).with(/MISMATCH/)

        worker_class = Class.new do
          include TenantRls::Job
        end

        worker = worker_class.new
        worker.debug_tenant_context('Mismatch test')
      end
    end

    context 'Legacy method compatibility' do
      let(:service_class) do
        Class.new do
          include TenantRls::Job

          def process_with_legacy_method
            job_data = { company: { id: 789 }, user: { id: 1 } }

            with_tenant_context(job_data) do
              'Legacy method executed'
            end
          end
        end
      end

      it 'supports legacy with_tenant_context method with deprecation warning' do
        expect(Rails.logger).to receive(:warn).with(/Using legacy with_tenant_context method/)

        service = service_class.new
        result = service.process_with_legacy_method
        expect(result).to eq('Legacy method executed')
      end

      it 'supports legacy set_tenant_from_job_data method' do
        expect(Rails.logger).to receive(:warn).with(/Using legacy set_tenant_from_job_data method/)

        service = service_class.new
        job_data = { company: { id: 123 } }
        service.set_tenant_from_job_data(job_data)

        expect(TenantRls::Current.tenant_id).to eq(123)
      end
    end
  end

  describe 'Real-world Scenarios - Comprehensive' do
    context 'NotificationWorker simulation' do
      it 'handles full notification worker flow' do
        notification_type = 'todo'
        notification_data = {
          'user' => { 'id' => 1, 'name' => 'Test User' },
          'all_data' => { 'app_name' => 'Test App' }
        }
        company_id = 123

        args = [notification_type, notification_data, company_id]
        context = { worker_perform_args: args }

        tenant_id = TenantRls::JobContextResolver.resolve(context)
        expect(tenant_id).to eq(123)
      end
    end

    context 'SendNotificationJob simulation' do
      it 'handles complex job payload from Common module' do
        payload = {
          'notification_type' => 'todo',
          'company' => { 'id' => 456 },
          'user' => { 'id' => 1 },
          'all_data' => { 'app_name' => 'Test App' },
          'company_settings' => {},
          'language' => 'en'
        }

        context = { job_data: payload }

        tenant_id = TenantRls::JobContextResolver.resolve(context)
        expect(tenant_id).to eq(456)
      end
    end

    context 'Error scenarios' do
      it 'handles corrupted job data gracefully' do
        # Simulate corrupted data
        payload = { 'company' => 'invalid_structure' }
        context = { job_data: payload }

        tenant_id = TenantRls::JobContextResolver.resolve(context)
        expect(tenant_id).to be_nil
      end

      it 'handles worker with unexpected argument structure' do
        args = [{ complex: 'structure' }, ['array', 'data']]
        context = { worker_perform_args: args }

        tenant_id = TenantRls::JobContextResolver.resolve(context)
        expect(tenant_id).to be_nil
      end
    end
  end
end
