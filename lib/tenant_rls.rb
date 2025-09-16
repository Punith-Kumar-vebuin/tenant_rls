require 'tenant_rls/version'
require 'tenant_rls/configuration'
require 'tenant_rls/current'
require 'tenant_rls/tenant_resolver'
require 'tenant_rls/tenant_context_manager'
require 'tenant_rls/thread_context_manager'
require 'tenant_rls/tenant_thread'
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

  def self.capture_context
    ThreadContextManager.capture_current_context
  end

  def self.restore_context(context, &block)
    ThreadContextManager.restore_context_in_thread(context, &block)
  end

  # Check if debug logging is enabled
  def self.is_debugging?
    configuration.debug_logging == true
  end
end
