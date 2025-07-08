require 'tenant_rls/version'
require 'tenant_rls/configuration'
require 'tenant_rls/current'
require 'tenant_rls/tenant_resolver'
require 'tenant_rls/tenant_context_manager'
require 'tenant_rls/job'
require 'tenant_rls/controller'
require 'tenant_rls/context'
require 'tenant_rls/railtie' if defined?(Rails)

module TenantRls
  def self.with_tenant(tenant_id, &block)
    old_tenant_id = Current.tenant_id
    Current.tenant_id = tenant_id

    ApplicationRecord.with_tenant(tenant_id, &block)
  ensure
    Current.tenant_id = old_tenant_id
  end

  def self.current_tenant_id
    Current.tenant_id
  end

  def self.reset!
    Current.reset
  end
end
