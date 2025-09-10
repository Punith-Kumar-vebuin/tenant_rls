require 'tenant_rls/version'
require 'tenant_rls/configuration'
require 'tenant_rls/current'
require 'tenant_rls/tenant_resolver'
require 'tenant_rls/tenant_context_manager'
require 'tenant_rls/thread_context_manager'
require 'tenant_rls/thread_extensions'
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

  # Convenience methods for thread-safe operations
  def self.thread_with_context(&block)
    ThreadContextManager.with_tenant_context(&block)
  end

  def self.thread_with_context_and_connection(&block)
    ThreadContextManager.with_tenant_context_and_connection(&block)
  end

  def self.capture_context
    ThreadContextManager.capture_current_context
  end

  def self.restore_context(context, &block)
    ThreadContextManager.restore_context_in_thread(context, &block)
  end
end
