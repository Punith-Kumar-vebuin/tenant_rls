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

    # Minimal enhancement: Smart cleanup based on request context
    if Current.respond_to?(:in_request_context?) && Current.in_request_context?
      # During request context: Don't reset immediately (for helpers/modules)
      ApplicationRecord.with_tenant(tenant_id, &block)
    else
      # Original behavior: Immediate reset for non-request contexts (jobs, manual calls)
      begin
        ApplicationRecord.with_tenant(tenant_id, &block)
      ensure
        Current.tenant_id = old_tenant_id
      end
    end
  ensure
    # Always reset thread-local tenant_id unless we're in a request context
    unless Current.respond_to?(:in_request_context?) && Current.in_request_context?
      Current.tenant_id = old_tenant_id
    end
  end

  def self.current_tenant_id
    # Primary: thread-local variable (fastest)
    tenant_id = Current.tenant_id
    return tenant_id if tenant_id.present?

    # Minimal enhancement: Fallback to database session variable (for helpers/modules)
    begin
      ApplicationRecord.current_tenant_id
    rescue => e
      Rails.logger.debug { "[TenantRls] Failed to get current_tenant_id from DB: #{e.message}" } if defined?(Rails)
      nil
    end
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
