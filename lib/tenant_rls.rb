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

  # Create a long-running thread with dedicated connection management (for Puma/export tasks)
  # This explicitly uses connection pooling and is ideal for tasks that outlive request cycles
  # @yield Block to execute in thread with dedicated database connection and tenant context
  # @return [Thread] The created thread with dedicated connection and tenant context
  def self.long_running_thread(&block)
    context = ThreadContextManager.capture_current_context
    Thread.send(:create_thread_with_connection_management, context, &block)
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
