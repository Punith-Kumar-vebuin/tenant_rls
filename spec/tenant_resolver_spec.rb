require 'spec_helper'

RSpec.describe TenantRls::TenantResolver do
  describe '.resolve_tenant_id' do
    it 'uses the configured strategy' do
      TenantRls.configure {|config| config.tenant_resolver_strategy = :manual }

      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(tenant_id: 123)
      expect(tenant_id).to eq(123)
    end

    it 'raises error for unknown strategy' do
      allow(TenantRls.configuration).to receive(:tenant_resolver_strategy).and_return(:unknown)

      expect {
        TenantRls::TenantResolver.resolve_tenant_id({})
      }.to raise_error(ArgumentError, /Unknown tenant resolver strategy/)
    end
  end
end

RSpec.describe TenantRls::WardenResolver do
  describe '.resolve' do
    it 'extracts tenant_id from warden user' do
      mock_user = double('User')
      mock_companies_users = double('CompaniesUsers')
      allow(mock_companies_users).to receive(:company_id).and_return(123)
      allow(mock_user).to receive(:companies_users).and_return([mock_companies_users])

      mock_request = double('Request')
      mock_env = { 'warden' => double('Warden', user: mock_user) }
      allow(mock_request).to receive(:env).and_return(mock_env)

      context = { request: mock_request }
      tenant_id = TenantRls::WardenResolver.resolve(context)

      expect(tenant_id).to eq(123)
    end

    it 'returns nil when no warden user' do
      mock_request = double('Request')
      allow(mock_request).to receive(:env).and_return({})

      context = { request: mock_request }
      tenant_id = TenantRls::WardenResolver.resolve(context)

      expect(tenant_id).to be_nil
    end
  end
end

RSpec.describe TenantRls::CustomAuthResolver do
  describe '.resolve' do
    it 'extracts tenant_id from current_company' do
      mock_company = double('Company', id: 456)
      context = { current_company: mock_company }

      tenant_id = TenantRls::CustomAuthResolver.resolve(context)
      expect(tenant_id).to eq(456)
    end

    it 'returns nil when no current_company' do
      context = {}
      tenant_id = TenantRls::CustomAuthResolver.resolve(context)
      expect(tenant_id).to be_nil
    end
  end
end

RSpec.describe TenantRls::JobContextResolver do
  describe '.resolve' do
    it 'extracts tenant_id from job_data company_id' do
      job_data = { company_id: 789 }
      context = { job_data: job_data }

      tenant_id = TenantRls::JobContextResolver.resolve(context)
      expect(tenant_id).to eq(789)
    end

    it 'extracts tenant_id from nested company object' do
      job_data = { company: { id: 101 } }
      context = { job_data: job_data }

      tenant_id = TenantRls::JobContextResolver.resolve(context)
      expect(tenant_id).to eq(101)
    end

    it 'handles string keys' do
      job_data = { 'company' => { 'id' => 202 } }
      context = { job_data: job_data }

      tenant_id = TenantRls::JobContextResolver.resolve(context)
      expect(tenant_id).to eq(202)
    end

    it 'returns nil when no job_data' do
      context = {}
      tenant_id = TenantRls::JobContextResolver.resolve(context)
      expect(tenant_id).to be_nil
    end
  end
end

RSpec.describe TenantRls::ManualResolver do
  describe '.resolve' do
    it 'returns tenant_id from context' do
      context = { tenant_id: 999 }
      tenant_id = TenantRls::ManualResolver.resolve(context)
      expect(tenant_id).to eq(999)
    end

    it 'returns nil when no tenant_id in context' do
      context = {}
      tenant_id = TenantRls::ManualResolver.resolve(context)
      expect(tenant_id).to be_nil
    end
  end
end
