# Thread Context Manager for TenantRls
# Simplified version - provides utilities for capturing and restoring tenant context
# Used internally by the gem and available for advanced use cases

module TenantRls
  module ThreadContextManager
    extend self

    # Captures the current tenant context for use in a new thread
    # Returns a hash containing all necessary context data to restore tenant state
    def capture_current_context
      tenant_id = TenantRls::Current.tenant_id
      user = TenantRls::Current.user

      if TenantRls.is_debugging?
        Rails.logger.debug { "[TenantRls] Capturing thread context: tenant_id=#{tenant_id.inspect}, user_present=#{user.present?}" }
      end

      {
        tenant_id: tenant_id,
        user: user,
        strategy: TenantRls.configuration.tenant_resolver_strategy,
        captured_at: Time.now
      }
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
        return yield if block_given?
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
  end
end
