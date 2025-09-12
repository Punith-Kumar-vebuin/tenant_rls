# Thread extensions to provide tenant-aware thread creation
# This file provides monkey patches to make tenant context preservation automatic

module TenantRls
  module ThreadExtensions
    # Extends the Thread class with tenant-aware methods
    module ThreadClassExtensions
      # DEPRECATED: Use Thread.new directly instead - it now automatically preserves tenant context
      def with_tenant_context(&block)
        Rails.logger.warn '[TenantRls] Thread.with_tenant_context is deprecated - use Thread.new directly' if defined?(Rails) && Rails.logger
        TenantRls::ThreadContextManager.with_tenant_context(&block)
      end

      # DEPRECATED: Use Thread.new directly instead - it now automatically preserves tenant context
      def with_tenant_context_and_connection(&block)
        Rails.logger.warn '[TenantRls] Thread.with_tenant_context_and_connection is deprecated - use Thread.new directly' if defined?(Rails) && Rails.logger
        TenantRls::ThreadContextManager.with_tenant_context(&block)
      end

      # Lightweight automatic Thread.new with tenant context preservation
      # This replaces Thread.new to automatically preserve tenant_id and user context
      # Does NOT hold database connections - Rails handles connections per operation
      #
      # @param args [Array] Arguments passed to original Thread.new
      # @yield Block to execute in new thread with tenant context preserved
      # @return [Thread] The created thread with tenant context
      def new_with_tenant_context(*args, &block)
        # Check if we have tenant context to preserve
        tenant_id = TenantRls::Current.tenant_id
        if tenant_id && tenant_id != '' && tenant_id.to_s.strip != ''
          # Capture current context before thread creation
          context = TenantRls::ThreadContextManager.capture_current_context

          if TenantRls.is_debugging?
            Rails.logger.debug { "[TenantRls] Auto-capturing tenant context for Thread.new: tenant_id=#{context[:tenant_id]}" }
          end

          # Create thread with automatic tenant context restoration
          # LIGHTWEIGHT: No connection pooling - let Rails handle connections per operation
          new_without_tenant_context(*args) do
            # Restore tenant context in the new thread
            TenantRls::Current.tenant_id = context[:tenant_id]
            TenantRls::Current.user = context[:user]

            if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
              Rails.logger.debug { "[TenantRls] Auto-restored tenant_id=#{context[:tenant_id]} in Thread.new" }
            end

            # Execute the original block - Rails will handle DB connections automatically
            yield if block_given?

          rescue => e
            if defined?(Rails) && Rails.logger
              Rails.logger.error "[TenantRls] Error in auto-tenant Thread.new: #{e.class}: #{e.message}"
              Rails.logger.error "[TenantRls] Backtrace: #{e.backtrace&.first(3)&.join('\n  ')}"
            end
            raise
          ensure
            # Clean up thread-local variables
            TenantRls::Current.reset if defined?(TenantRls::Current)
          end
        else
          # No tenant context, use original Thread.new behavior
          new_without_tenant_context(*args, &block)
        end
      end
    end

    # Instance methods for Thread objects
    module ThreadInstanceExtensions
      # Marks this thread as having preserved tenant context (for warning suppression)
      def mark_tenant_context_preserved!
        self[:tenant_rls_context_preserved] = true
      end

      # Checks if this thread has tenant context
      def has_tenant_context?
        TenantRls::ThreadContextManager.has_tenant_context?
      end

      # Gets current thread's tenant context info
      def tenant_context_info
        TenantRls::ThreadContextManager.current_context_info
      end
    end
  end
end

# Apply the extensions to Thread class
class Thread
  extend TenantRls::ThreadExtensions::ThreadClassExtensions
  include TenantRls::ThreadExtensions::ThreadInstanceExtensions

  # Enable automatic tenant context preservation for Thread.new (if configured)
  # This makes Thread.new automatically inherit tenant context - NO CODE CHANGES NEEDED!
  begin
    if TenantRls.configuration.auto_thread_tenant_context
      class << self
        alias_method :new_without_tenant_context, :new
        alias_method :new, :new_with_tenant_context
      end

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.info '[TenantRls] Automatic Thread.new tenant context preservation enabled'
      end
    end
  rescue => e
    # If configuration fails during initialization, log and continue without patching
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.error "[TenantRls] Failed to enable auto Thread.new patching: #{e.message}"
    else
      Rails.logger.error "[TenantRls] Failed to enable auto Thread.new patching: #{e.message}"
    end
  end
end
