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

      # Automatic Thread.new with tenant context preservation
      # This replaces the original Thread.new to automatically capture and restore tenant context
      # Works transparently - developers can use Thread.new normally and tenant context is preserved
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
          
          if TenantRls.configuration.debug_logging
            Rails.logger.debug "[TenantRls] Auto-capturing tenant context for Thread.new: tenant_id=#{context[:tenant_id]}"
          end
          
          # Create thread with automatic tenant context restoration
          new_without_tenant_context(*args) do
            thread_execution = -> do
              begin
                # Restore tenant context in the new thread
                TenantRls::Current.tenant_id = context[:tenant_id]
                TenantRls::Current.user = context[:user]
                
                # Set PostgreSQL RLS variable for the thread
                ApplicationRecord.with_tenant(context[:tenant_id]) do
                  if TenantRls.configuration.debug_logging
                    Rails.logger.debug "[TenantRls] Auto-restored tenant_id=#{context[:tenant_id]} in Thread.new"
                  end
                  
                  # Execute the original block with full Rails environment
                  yield if block_given?
                end
              rescue => e
                Rails.logger.error "[TenantRls] Error in auto-tenant Thread.new: #{e.message}"
                raise
              ensure
                # Clean up thread-local variables
                TenantRls::Current.reset if defined?(TenantRls::Current)
              end
            end
            
            # Use database connection if configured (default: true for safety)
            if TenantRls.configuration.auto_thread_with_connection != false
              ActiveRecord::Base.connection_pool.with_connection(&thread_execution)
            else
              thread_execution.call
            end
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
  if TenantRls.configuration.auto_thread_tenant_context
    class << self
      alias_method :new_without_tenant_context, :new
      alias_method :new, :new_with_tenant_context
    end
  end
end
