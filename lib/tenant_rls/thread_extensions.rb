# Thread extensions to provide tenant-aware thread creation
# This file provides monkey patches to make tenant context preservation automatic

module TenantRls
  module ThreadExtensions
    # Extends the Thread class with tenant-aware methods
    module ThreadClassExtensions
      # Creates a new thread with tenant context preserved from the current thread
      # This is a drop-in replacement for Thread.new that maintains RLS context
      #
      # Usage:
      #   Thread.with_tenant_context do
      #     # Your work here - tenant_id is preserved
      #   end
      #
      # @yield Block to execute in new thread with tenant context
      # @return [Thread] The created thread
      def with_tenant_context(&block)
        TenantRls::ThreadContextManager.with_tenant_context(&block)
      end

      # Creates a new thread with both tenant context and database connection management
      # This combines Thread.new with ActiveRecord connection pooling and tenant context
      #
      # Usage:
      #   Thread.with_tenant_context_and_connection do
      #     # Your database work here - both connection and tenant_id are managed
      #   end
      #
      # @yield Block to execute in new thread with managed connection and tenant context
      # @return [Thread] The created thread
      def with_tenant_context_and_connection(&block)
        TenantRls::ThreadContextManager.with_tenant_context_and_connection(&block)
      end

      # Creates a new thread and warns if tenant context might be lost
      # This maintains backward compatibility while alerting to potential issues
      #
      # @param args [Array] Arguments passed to original Thread.new
      # @yield Block to execute in new thread
      # @return [Thread] The created thread
      def new_with_tenant_warning(*args, &block)
        if TenantRls::Current.tenant_id.present? && !Thread.current[:tenant_rls_context_preserved]
          Rails.logger.warn "[TenantRls] Thread.new called with active tenant context (#{TenantRls::Current.tenant_id}) - consider using Thread.with_tenant_context instead"
        end
        new_without_tenant_warning(*args, &block)
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

  # Optional: Enable warnings for Thread.new usage (comment out if too noisy)
  # class << self
  #   alias_method :new_without_tenant_warning, :new
  #   alias_method :new, :new_with_tenant_warning
  # end
end
