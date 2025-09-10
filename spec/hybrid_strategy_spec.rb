require 'spec_helper'

RSpec.describe 'Hybrid Strategy - Comprehensive Test Suite' do
  before do
    TenantRls.configure do |config|
      config.tenant_resolver_strategy = :hybrid
      config.tenant_id_column = :company_id
      config.debug_logging = true
    end
  end

  after do
    TenantRls.reset!
    # Clean up all thread variables
    Thread.current[:sidekiq_context] = nil
    Thread.current[:sidekiq_worker] = nil
    Thread.current[:sidekiq_processor] = nil
    Thread.current[:tenant_rls_sidekiq_context] = nil
    Thread.current[:tenant_rls_sidekiq_worker] = nil
  end

  describe 'HybridResolver Core Functionality' do
    describe '.resolve' do
      context 'when in Sidekiq context' do
        it 'detects Sidekiq context via thread variables and uses JobContextResolver' do
          Thread.current[:sidekiq_context] = true
          Thread.current[:sidekiq_worker] = 'TestWorker'

          begin
            job_data = { company_id: 123 }
            context = { job_data: job_data }

            tenant_id = TenantRls::HybridResolver.resolve(context)
            expect(tenant_id).to eq(123)
          ensure
            Thread.current[:sidekiq_context] = nil
            Thread.current[:sidekiq_worker] = nil
          end
        end

        it 'detects Sidekiq context via job data presence and uses JobContextResolver' do
          job_data = { company_id: 456 }
          context = { job_data: job_data }

          tenant_id = TenantRls::HybridResolver.resolve(context)
          expect(tenant_id).to eq(456)
        end

        it 'detects Sidekiq context via worker args presence and uses JobContextResolver' do
          args = ['notification', { user: { id: 1 } }, 789]
          context = { worker_perform_args: args }

          tenant_id = TenantRls::HybridResolver.resolve(context)
          expect(tenant_id).to eq(789)
        end
      end

      context 'when in web request context' do
        it 'detects web request context with Warden and resolves tenant' do
          mock_user = double('User')
          mock_companies_users = double('CompaniesUsers')
          allow(mock_companies_users).to receive(:company_id).and_return(321)
          allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

          mock_request = double('Request')
          mock_warden = double('Warden', user: mock_user)
          mock_env = { 'warden' => mock_warden }
          allow(mock_request).to receive(:env).and_return(mock_env)
          allow(mock_request).to receive(:respond_to?).with(:env).and_return(true)

          context = { request: mock_request }
          tenant_id = TenantRls::HybridResolver.resolve(context)

          expect(tenant_id).to eq(321)
        end

        it 'prioritizes Warden context over job data when both are present' do
          mock_user = double('User')
          mock_companies_users = double('CompaniesUsers')
          allow(mock_companies_users).to receive(:company_id).and_return(456)
          allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

          mock_request = double('Request')
          mock_warden = double('Warden', user: mock_user)
          mock_env = { 'warden' => mock_warden }
          allow(mock_request).to receive(:env).and_return(mock_env)
          allow(mock_request).to receive(:respond_to?).with(:env).and_return(true)

          # Even with job data present, Warden should take priority
          context = {
            request: mock_request,
            job_data: { company_id: 999 }  # This should be ignored
          }

          tenant_id = TenantRls::HybridResolver.resolve(context)
          expect(tenant_id).to eq(456)  # Warden result, not job data
        end
      end

      context 'context detection priority' do
        it 'prioritizes thread context over data context' do
          Thread.current[:sidekiq_context] = true
          Thread.current[:sidekiq_worker] = 'TestWorker'

          begin
            # Even though we have request data, thread context should win
            mock_request = double('Request')
            allow(mock_request).to receive(:env).and_return({})

            context = {
              request: mock_request,
              job_data: { company_id: 123 }
            }

            # Should use JobContextResolver due to thread context
            tenant_id = TenantRls::HybridResolver.resolve(context)
            expect(tenant_id).to eq(123)
          ensure
            Thread.current[:sidekiq_context] = nil
            Thread.current[:sidekiq_worker] = nil
          end
        end
      end
    end
  end

  describe 'Direct Tenant ID Extraction' do
    it 'finds company_id in any argument position' do
      # Test all possible positions
      test_cases = [
        [123, 'notification', { user: { id: 1 } }],      # First position
        ['notification', 456, { user: { id: 1 } }],      # Second position
        ['notification', { user: { id: 1 } }, 789],      # Third position
        ['type', 'data', { user: { id: 1 } }, 321]       # Fourth position
      ]

      test_cases.each_with_index do |args, index|
        context = { worker_perform_args: args }
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

        expected_id = [123, 456, 789, 321][index]
        expect(tenant_id).to eq(expected_id), "Failed for args: #{args.inspect}"
      end
    end

    it 'extracts tenant_id from hash arguments using configured column' do
      # Test with default company_id
      args_company = ['notification', { company_id: 555, user: { id: 1 } }]
      context_company = { worker_perform_args: args_company }
      expect(TenantRls::TenantResolver.resolve_tenant_id(context_company)).to eq(555)

      # Test with custom tenant_id_column
      TenantRls.configure {|c| c.tenant_id_column = :account_id }

      args_account = ['notification', { account_id: 666, user: { id: 1 } }]
      context_account = { worker_perform_args: args_account }
      expect(TenantRls::TenantResolver.resolve_tenant_id(context_account)).to eq(666)
    end

    it 'prioritizes direct integer over hash values' do
      # When both are present, integer takes priority
      args = [777, { company_id: 888, user: { id: 1 } }]
      context = { worker_perform_args: args }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

      expect(tenant_id).to eq(777) # Direct integer wins
    end
  end

  describe 'Sidekiq Version Compatibility' do
    context 'Sidekiq 5.x compatibility' do
      before do
        # Mock Sidekiq 5.x
        stub_const('Sidekiq::VERSION', '5.2.7')
        allow(Sidekiq).to receive(:const_defined?).with('VERSION').and_return(true)
      end

      it 'uses thread variables for version 5.x' do
        Thread.current.thread_variable_set(:sidekiq_processor, true)

        begin
          context = { job_data: { company_id: 501 } }
          tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
          expect(tenant_id).to eq(501)
        ensure
          Thread.current.thread_variable_set(:sidekiq_processor, nil)
        end
      end
    end

    context 'Sidekiq 7.x compatibility' do
      before do
        # Mock Sidekiq 7.x
        stub_const('Sidekiq::VERSION', '7.1.0')
        allow(Sidekiq).to receive(:const_defined?).with('VERSION').and_return(true)
      end

      it 'uses thread-local storage for version 7.x' do
        Thread.current[:sidekiq_processor] = true

        begin
          context = { job_data: { company_id: 701 } }
          tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
          expect(tenant_id).to eq(701)
        ensure
          Thread.current[:sidekiq_processor] = nil
        end
      end
    end
  end

  describe 'Sidekiq Logging Compatibility' do
    describe 'ThreadContextManager' do
      it 'sets thread context without interfering with Sidekiq logger' do
        # This should not cause any NoMethodError when Sidekiq tries to log
        TenantRls::Job::ThreadContextManager.setup_sidekiq_context('TestWorker')

        # Verify our custom variables are set correctly (methods should be public)
        expect(TenantRls::Job::ThreadContextManager.in_sidekiq_context?).to be true
        expect(TenantRls::Job::ThreadContextManager.current_sidekiq_worker).to eq('TestWorker')

        # Verify we don't set the problematic :sidekiq_context variable
        expect(Thread.current[:sidekiq_context]).to be_nil

        # Verify our custom variable is set
        expect(Thread.current[:tenant_rls_sidekiq_context]).to be true

        # Clean up
        TenantRls::Job::ThreadContextManager.cleanup_sidekiq_context

        # Verify cleanup works
        expect(TenantRls::Job::ThreadContextManager.in_sidekiq_context?).to be false
        expect(TenantRls::Job::ThreadContextManager.current_sidekiq_worker).to be_nil
      end

      it 'does not set problematic thread variables that cause logger errors' do
        TenantRls::Job::ThreadContextManager.setup_sidekiq_context('TestWorker')

        # The problematic variable that was causing the error should not be set
        expect(Thread.current[:sidekiq_context]).to be_nil

        # Our safe variable should be set
        expect(Thread.current[:tenant_rls_sidekiq_context]).to be true

        # This should not raise NoMethodError: undefined method 'any?' for true
        expect {
          # Simulate what Sidekiq logger does
          ctx = Thread.current[:sidekiq_context]
          ctx.any? if ctx.respond_to?(:any?)
        }.not_to raise_error

        TenantRls::Job::ThreadContextManager.cleanup_sidekiq_context
      end

      it 'hybrid resolver detects Sidekiq context using safe variables' do
        TenantRls::Job::ThreadContextManager.setup_sidekiq_context('TestWorker')

        begin
          context = { job_data: { company_id: 123 } }
          tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

          expect(tenant_id).to eq(123)
        ensure
          TenantRls::Job::ThreadContextManager.cleanup_sidekiq_context
        end
      end
    end
  end

  describe 'Configuration Flexibility' do
    it 'adapts to different tenant_id_column configurations' do
      configurations = [
        { column: :company_id, test_data: { company_id: 1001 } },
        { column: :account_id, test_data: { account_id: 1002 } },
        { column: :tenant_id, test_data: { tenant_id: 1003 } },
        { column: :organization_id, test_data: { organization_id: 1004 } }
      ]

      configurations.each do |config|
        TenantRls.configure {|c| c.tenant_id_column = config[:column] }

        context = { job_data: config[:test_data] }
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

        expected_id = config[:test_data].values.first
        expect(tenant_id).to eq(expected_id), "Failed for column: #{config[:column]}"
      end
    end

    it 'handles nested tenant objects with dynamic keys' do
      TenantRls.configure {|c| c.tenant_id_column = :account_id }

      # Should look for 'account' object when tenant_id_column is :account_id
      context = { job_data: { account: { id: 2001 } } }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
      expect(tenant_id).to eq(2001)

      # Test with organization
      TenantRls.configure {|c| c.tenant_id_column = :organization_id }

      context = { job_data: { organization: { id: 2002 } } }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
      expect(tenant_id).to eq(2002)
    end
  end

  describe 'Error Handling and Edge Cases' do
    it 'handles nil and invalid arguments gracefully' do
      invalid_contexts = [
        { worker_perform_args: nil },
        { worker_perform_args: [] },
        { worker_perform_args: ['string', 'another_string'] },
        { worker_perform_args: [0, -1, 'invalid'] },
        { job_data: nil },
        { job_data: {} },
        {}
      ]

      invalid_contexts.each do |context|
        expect {
          tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
          expect(tenant_id).to be_nil
        }.not_to raise_error
      end
    end

    it 'handles invalid tenant IDs appropriately' do
      # Negative tenant IDs should be rejected
      job_data = { company_id: -1 }
      context = { job_data: job_data }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
      expect(tenant_id).to be_nil

      # Zero tenant IDs should be rejected
      job_data_zero = { company_id: 0 }
      context_zero = { job_data: job_data_zero }
      tenant_id_zero = TenantRls::TenantResolver.resolve_tenant_id(context_zero)
      expect(tenant_id_zero).to be_nil

      # String tenant IDs should be rejected
      job_data_string = { company_id: '123' }
      context_string = { job_data: job_data_string }
      tenant_id_string = TenantRls::TenantResolver.resolve_tenant_id(context_string)
      expect(tenant_id_string).to be_nil
    end

    it 'falls back gracefully when context detection is ambiguous' do
      # Empty context should return nil
      empty_context = {}
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(empty_context)
      expect(tenant_id).to be_nil

      # Unknown context keys should also return nil
      unknown_context = { unknown_key: 'unknown_value' }
      tenant_id_unknown = TenantRls::TenantResolver.resolve_tenant_id(unknown_context)
      expect(tenant_id_unknown).to be_nil
    end
  end

  describe 'Thread Safety' do
    it 'maintains thread safety during concurrent operations' do
      threads = []
      results = []
      mutex = Mutex.new

      10.times do |i|
        threads << Thread.new do
          Thread.current[:sidekiq_context] = true
          Thread.current[:sidekiq_worker] = "Worker#{i}"

          context = { job_data: { company_id: 1000 + i } }
          tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

          mutex.synchronize { results << tenant_id }

          Thread.current[:sidekiq_context] = nil
          Thread.current[:sidekiq_worker] = nil
        end
      end

      threads.each(&:join)

      expect(results.sort).to eq((1000..1009).to_a)
    end

    it 'properly sets and cleans up thread context during Sidekiq execution' do
      # Verify thread context is initially clean
      expect(Thread.current[:sidekiq_context]).to be_nil
      expect(Thread.current[:sidekiq_worker]).to be_nil

      # Simulate Sidekiq worker execution with thread context
      Thread.current[:sidekiq_context] = true
      Thread.current[:sidekiq_worker] = 'TestWorker'

      begin
        job_data = { company_id: 700 }
        context = { job_data: job_data }

        # Should detect Sidekiq context from thread variables
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
        expect(tenant_id).to eq(700)

        # Verify thread context is still set
        expect(Thread.current[:sidekiq_context]).to be true
        expect(Thread.current[:sidekiq_worker]).to eq('TestWorker')
      ensure
        # Clean up thread context (simulating ensure block in real implementation)
        Thread.current[:sidekiq_context] = nil
        Thread.current[:sidekiq_worker] = nil
      end

      # Verify thread context is cleaned up
      expect(Thread.current[:sidekiq_context]).to be_nil
      expect(Thread.current[:sidekiq_worker]).to be_nil
    end
  end

  describe 'Real-world Integration Scenarios' do
    it 'handles mixed API and background job workflow' do
      # Simulate API request creating a background job

      # 1. API Request (Warden context)
      mock_user = double('User')
      mock_companies_users = double('CompaniesUsers', company_id: 5000)
      allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

      mock_request = double('Request')
      mock_warden = double('Warden', user: mock_user)
      mock_env = { 'warden' => mock_warden }
      allow(mock_request).to receive(:env).and_return(mock_env)
      allow(mock_request).to receive(:respond_to?).with(:env).and_return(true)

      api_context = { request: mock_request }
      api_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(api_context)
      expect(api_tenant_id).to eq(5000)

      # 2. Background job processing (same tenant)
      job_context = { worker_perform_args: ['process_data', { record_id: 123 }, 5000] }
      job_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(job_context)
      expect(job_tenant_id).to eq(5000)

      # Verify consistency
      expect(api_tenant_id).to eq(job_tenant_id)
    end

    it 'handles legacy repository migration scenario' do
      # Simulate a legacy repo with both Warden and Sidekiq requirements

      # Legacy Warden setup (would previously use :warden strategy)
      mock_user = double('User')
      mock_companies_users = double('CompaniesUsers', company_id: 9000)
      allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

      mock_request = double('Request')
      mock_warden = double('Warden', user: mock_user)
      mock_env = { 'warden' => mock_warden }
      allow(mock_request).to receive(:env).and_return(mock_env)
      allow(mock_request).to receive(:respond_to?).with(:env).and_return(true)

      # Legacy Sidekiq setup (would previously use :job_context strategy)
      Thread.current[:sidekiq_context] = true
      Thread.current[:sidekiq_worker] = 'LegacyWorker'

      begin
        # Both should work with hybrid strategy
        web_context = { request: mock_request }
        web_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(web_context)
        expect(web_tenant_id).to eq(9000)

        job_context = { job_data: { company_id: 9000 } }
        job_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(job_context)
        expect(job_tenant_id).to eq(9000)

        expect(web_tenant_id).to eq(job_tenant_id)
      ensure
        Thread.current[:sidekiq_context] = nil
        Thread.current[:sidekiq_worker] = nil
      end
    end

    it 'handles API request followed by background job processing' do
      # Step 1: API request creates a record and queues a background job
      mock_user = double('User')
      mock_companies_users = double('CompaniesUsers', company_id: 800)
      allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

      mock_request = double('Request')
      mock_warden = double('Warden', user: mock_user)
      mock_env = { 'warden' => mock_warden }
      allow(mock_request).to receive(:env).and_return(mock_env)
      allow(mock_request).to receive(:respond_to?).with(:env).and_return(true)

      # API request context
      api_context = { request: mock_request }
      api_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(api_context)
      expect(api_tenant_id).to eq(800)

      # Step 2: Background job processes the queued work
      # (In real scenario, company_id would be passed to the job)
      job_args = ['process_data', { record_id: 123 }, 800] # company_id passed as last arg
      job_context = { worker_perform_args: job_args }
      job_tenant_id = TenantRls::TenantResolver.resolve_tenant_id(job_context)
      expect(job_tenant_id).to eq(800)

      # Verify both contexts resolved to the same tenant
      expect(api_tenant_id).to eq(job_tenant_id)
    end
  end

  describe 'Legacy Compatibility' do
    it 'maintains backward compatibility with company_id patterns' do
      # Test legacy company_id still works
      job_data = { company_id: 500 }
      context = { job_data: job_data }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
      expect(tenant_id).to eq(500)

      # Test legacy company object still works
      job_data_company = { company: { id: 600 } }
      context_company = { job_data: job_data_company }
      tenant_id_company = TenantRls::TenantResolver.resolve_tenant_id(context_company)
      expect(tenant_id_company).to eq(600)
    end

    it 'works with different tenant_id_column configurations' do
      # Test with account_id instead of company_id
      TenantRls.configure do |config|
        config.tenant_resolver_strategy = :hybrid
        config.tenant_id_column = :account_id
      end

      # Job context with account_id
      job_data = { account_id: 300 }
      context = { job_data: job_data }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
      expect(tenant_id).to eq(300)

      # Test nested account object
      job_data_nested = { account: { id: 400 } }
      context_nested = { job_data: job_data_nested }
      tenant_id_nested = TenantRls::TenantResolver.resolve_tenant_id(context_nested)
      expect(tenant_id_nested).to eq(400)
    end
  end

  describe 'Strategy-Specific Tests' do
    it 'works with both job_context and hybrid strategies' do
      # Test job_context strategy
      TenantRls.configure {|c| c.tenant_resolver_strategy = :job_context }
      TenantRls::Job::ThreadContextManager.setup_sidekiq_context('TestWorker')

      begin
        context = { job_data: { company_id: 456 } }
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
        expect(tenant_id).to eq(456)
      ensure
        TenantRls::Job::ThreadContextManager.cleanup_sidekiq_context
      end

      # Test hybrid strategy
      TenantRls.configure {|c| c.tenant_resolver_strategy = :hybrid }
      TenantRls::Job::ThreadContextManager.setup_sidekiq_context('TestWorker')

      begin
        context = { job_data: { company_id: 789 } }
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
        expect(tenant_id).to eq(789)
      ensure
        TenantRls::Job::ThreadContextManager.cleanup_sidekiq_context
      end
    end
  end
end
