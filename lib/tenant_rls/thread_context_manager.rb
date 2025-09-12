# Thread Context Manager for TenantRls
# This module provides thread-safe utilities for preserving tenant context
# across thread boundaries, ensuring RLS continues to work properly in
# background threads spawned with Thread.new

module TenantRls
  module ThreadContextManager
    extend self

    # Captures the current tenant context for use in a new thread
    # Returns a hash containing all necessary context data to restore tenant state
    def capture_current_context
      tenant_id = TenantRls::Current.tenant_id
      user = TenantRls::Current.user

      if TenantRls.is_debugging?
        Rails.logger.debug "[TenantRls] Capturing thread context: tenant_id=#{tenant_id.inspect}, user_present=#{user.present?}"
      end

      {
        tenant_id: tenant_id,
        user: user,
        strategy: TenantRls.configuration.tenant_resolver_strategy,
        captured_at: Time.zone.now
      }
    end

    # Executes a block within a new thread, preserving the current tenant context
    # This is a thread-safe replacement for Thread.new that maintains tenant context
    #
    # Usage:
    #   TenantRls::ThreadContextManager.with_tenant_context do
    #     # Your background work here
    #     # tenant_id and user context are preserved
    #   end
    #
    # Returns: Thread object
    def with_tenant_context(&block)
      context = capture_current_context

      if TenantRls.is_debugging?
        Rails.logger.debug "[TenantRls] Creating thread with tenant context: tenant_id=#{context[:tenant_id].inspect}"
      end

      Thread.new do
        restore_context_in_thread(context, &block)
      ensure
        if TenantRls.is_debugging?
          Rails.logger.debug "[TenantRls] Cleaning up thread context: tenant_id=#{context[:tenant_id].inspect}"
        end
        TenantRls::Current.reset
      end
    end

    # Executes a block within a new thread with database connection management
    # This combines tenant context preservation with ActiveRecord connection pooling
    #
    # Usage:
    #   TenantRls::ThreadContextManager.with_tenant_context_and_connection do
    #     # Your database work here with tenant context preserved
    #   end
    #
    # Returns: Thread object
    def with_tenant_context_and_connection(&block)
      context = capture_current_context

      if TenantRls.is_debugging?
        Rails.logger.debug { "[TenantRls] Creating thread with DB connection: tenant_id=#{context[:tenant_id].inspect}" }
      end

      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          if TenantRls.is_debugging?
            Rails.logger.debug { "[TenantRls] Acquired DB connection in thread for tenant_id=#{context[:tenant_id].inspect}" }
          end
          restore_context_in_thread(context, &block)
        ensure
          if TenantRls.is_debugging?
            Rails.logger.debug { "[TenantRls] Cleaning up thread context and DB connection: tenant_id=#{context[:tenant_id].inspect}" }
          end
          TenantRls::Current.reset
        end
      end
    end

    # Manually restores tenant context in the current thread from captured context
    # Useful for custom thread management scenarios
    #
    # @param context [Hash] Context hash returned by capture_current_context
    def restore_context_in_thread(context, &block)
      return unless context.is_a?(Hash)

      tenant_id = context[:tenant_id]
      user = context[:user]

      # Skip if no tenant context was captured
      if tenant_id.blank?
        if TenantRls.is_debugging?
          Rails.logger.warn '[TenantRls] No tenant_id to restore in thread context'
        end
        return
      end

      if TenantRls.is_debugging?
        Rails.logger.debug { "[TenantRls] Restoring tenant context: tenant_id=#{tenant_id.inspect}" }
      end

      # Set the thread-local variables
      TenantRls::Current.tenant_id = tenant_id
      TenantRls::Current.user = user

      # Set the database-level tenant context for RLS if block is provided
      if block_given?
        ApplicationRecord.with_tenant(tenant_id) do
          if TenantRls.is_debugging?
            begin
              # Verify the RLS setting was applied correctly
              db_tenant_id = ApplicationRecord.connection.execute('SHOW tenant_rls.tenant_id').first&.fetch('tenant_rls.tenant_id', 'not_set')
              Rails.logger.debug { "[TenantRls] SET tenant_rls.tenant_id=#{tenant_id.inspect} (DB verification: #{db_tenant_id})" }
            rescue => e
              Rails.logger.warn "[TenantRls] Could not verify DB tenant setting: #{e.message}"
            end
          end
          yield
        end
      end
    end

    # Creates a context-aware thread that automatically preserves tenant state
    # This method provides maximum flexibility for custom threading scenarios
    #
    # @param context [Hash, nil] Optional pre-captured context. If nil, captures current context
    # @param with_connection [Boolean] Whether to use connection pool management
    # @yield Block to execute in the new thread
    # @return [Thread] The created thread
    def create_context_aware_thread(context: nil, with_connection: true, &block)
      context ||= capture_current_context

      if TenantRls.is_debugging?
        connection_type = with_connection ? 'with DB connection' : 'without DB connection'
        Rails.logger.debug { "[TenantRls] Creating custom thread #{connection_type}: tenant_id=#{context[:tenant_id].inspect}" }
      end

      Thread.new do
        thread_block = -> do
          begin
            restore_context_in_thread(context, &block)
          ensure
            if TenantRls.is_debugging?
              Rails.logger.debug { "[TenantRls] Cleaning up custom thread context: tenant_id=#{context[:tenant_id].inspect}" }
            end
            TenantRls::Current.reset
          end
        end

        if with_connection
          ActiveRecord::Base.connection_pool.with_connection(&thread_block)
        else
          thread_block.call
        end
      end
    end

    # Checks if current thread has tenant context
    # Useful for debugging and conditional logic
    def has_tenant_context?
      TenantRls::Current.tenant_id.present?
    end

    # Returns current thread's tenant context info for debugging
    def current_context_info
      {
        thread_id: Thread.current.object_id,
        tenant_id: TenantRls::Current.tenant_id,
        user_present: TenantRls::Current.user.present?,
        strategy: TenantRls.configuration.tenant_resolver_strategy
      }
    end

    private
      # Internal method that handles the actual context restoration with proper RLS setup
      def restore_context_in_thread(context)
        tenant_id = context[:tenant_id]
        user = context[:user]

        return if tenant_id.blank?

        if TenantRls.is_debugging?
          Rails.logger.debug "[TenantRls::ThreadContext] Setting up tenant context in thread #{Thread.current.object_id}"
        end

        # Set thread-local context
        TenantRls::Current.tenant_id = tenant_id
        TenantRls::Current.user = user

        # The database tenant context is set by the with_tenant block in the calling method
      end
  end
end
