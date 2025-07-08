require 'bundler/setup'
require 'tenant_rls'
require 'rspec'
require 'active_record'
require 'rails'

module Rails
  def self.env
    @env ||= ActiveSupport::StringInquirer.new('test')
  end

  def self.logger
    @logger ||= Logger.new(STDOUT)
  end
end

RSpec.configure do |config|
  config.before(:each) do
    TenantRls.reset_configuration!
  end
end
