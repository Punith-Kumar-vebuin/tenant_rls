require 'spec_helper'

RSpec.describe TenantRls::Configuration do
  let(:config) { TenantRls::Configuration.new }

  describe '#initialize' do
    it 'sets default values' do
      expect(config.tenant_resolver_strategy).to eq(:warden)
      expect(config.tenant_id_column).to eq(:company_id)
      expect(config.debug_logging).to be false
    end
  end

  describe '#tenant_resolver_strategy=' do
    it 'accepts valid strategies' do
      config.tenant_resolver_strategy = :custom_auth
      expect(config.tenant_resolver_strategy).to eq(:custom_auth)
    end

    it 'raises error for invalid strategy' do
      expect {
        config.tenant_resolver_strategy = :invalid_strategy
      }.to raise_error(ArgumentError, /Invalid tenant resolver strategy/)
    end
  end

  describe '#valid_strategies' do
    it 'returns all valid strategies' do
      expected_strategies = [:warden, :custom_auth, :job_context, :manual]
      expect(config.valid_strategies).to eq(expected_strategies)
    end
  end
end

RSpec.describe TenantRls do
  describe '.configure' do
    it 'yields configuration for customization' do
      TenantRls.configure do |config|
        config.tenant_resolver_strategy = :custom_auth
        config.debug_logging = true
      end

      expect(TenantRls.configuration.tenant_resolver_strategy).to eq(:custom_auth)
      expect(TenantRls.configuration.debug_logging).to be true
    end
  end

  describe '.configuration' do
    it 'returns the same configuration instance' do
      config1 = TenantRls.configuration
      config2 = TenantRls.configuration
      expect(config1).to be(config2)
    end
  end

  describe '.reset_configuration!' do
    it 'resets configuration to defaults' do
      TenantRls.configure do |config|
        config.tenant_resolver_strategy = :custom_auth
        config.debug_logging = true
      end

      TenantRls.reset_configuration!

      expect(TenantRls.configuration.tenant_resolver_strategy).to eq(:warden)
      expect(TenantRls.configuration.debug_logging).to be false
    end
  end
end
