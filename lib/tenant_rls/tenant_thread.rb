# frozen_string_literal: true

module TenantRls
  # TenantThread - A simple Thread subclass that preserves tenant context
  # Use this instead of Thread.new when you need tenant context in background threads
  #
  # Example:
  #   TenantThread.new do
  #     # tenant_id is automatically available here
  #     SomeModel.create(name: "example")
  #   end
  #
  class TenantThread < Thread
    # Create a new thread with tenant context preserved
    # @param args [Array] Arguments passed to Thread constructor
    # @yield Block to execute in new thread with tenant context
    # @return [TenantThread] The created thread with tenant context
    def initialize(*args, &block)
      # Capture tenant context from current thread before spawning new thread
      captured_tenant_id = TenantRls::Current.tenant_id
      captured_user = TenantRls::Current.user

      # Debug logging
      if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
        Rails.logger.debug { "[TenantThread] Creating thread with tenant_id=#{captured_tenant_id}" }
      end

      # Create thread with captured context
      super(*args) do
        begin
          # Restore tenant context in the new thread
          TenantRls::Current.tenant_id = captured_tenant_id
          TenantRls::Current.user = captured_user

          if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
            Rails.logger.debug { "[TenantThread] Thread started with tenant_id=#{TenantRls::Current.tenant_id}" }
          end

          # Execute the user's block
          yield if block_given?

        rescue => e
          if defined?(Rails) && Rails.logger
            Rails.logger.error "[TenantThread] Error in tenant thread: #{e.class}: #{e.message}"
          end
          raise
        ensure
          # Clean up thread-local variables
          TenantRls::Current.reset if defined?(TenantRls::Current)

          if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
            Rails.logger.debug { "[TenantThread] Thread cleanup completed" }
          end
        end
      end
    end

    # Create a tenant thread with dedicated database connection management
    # Use this for long-running operations or when you need guaranteed database access
    # @param args [Array] Arguments passed to Thread constructor
    # @yield Block to execute with dedicated connection and tenant context
    # @return [TenantThread] The created thread with connection and tenant context
    def self.with_connection(*args, &block)
      # Capture tenant context from current thread
      captured_tenant_id = TenantRls::Current.tenant_id
      captured_user = TenantRls::Current.user

      if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
        Rails.logger.debug { "[TenantThread] Creating thread with connection, tenant_id=#{captured_tenant_id}" }
      end

      new(*args) do
        # Use dedicated database connection for this thread
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          begin
            # Restore tenant context
            TenantRls::Current.tenant_id = captured_tenant_id
            TenantRls::Current.user = captured_user

            # Set database session variable for tenant isolation (AWS RDS compatible)
            if captured_tenant_id && !captured_tenant_id.to_s.strip.empty?
              begin
                connection.execute("SET tenant_rls.tenant_id = #{connection.quote(captured_tenant_id)}")
                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantThread] SET tenant_rls.tenant_id=#{captured_tenant_id}" }
                end
              rescue => rls_error
                # AWS RDS Fallback: use application.tenant_id if tenant_rls.tenant_id not supported
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantThread] tenant_rls.tenant_id failed, using application.tenant_id: #{rls_error.message}"
                end
                connection.execute("SET application.tenant_id = #{connection.quote(captured_tenant_id)}")
              end
            end

            if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
              Rails.logger.debug { "[TenantThread] Thread with connection started, tenant_id=#{TenantRls::Current.tenant_id}" }
            end

            # Execute user's block with proper context and connection
            yield if block_given?

          rescue => e
            if defined?(Rails) && Rails.logger
              Rails.logger.error "[TenantThread] Error in connection thread: #{e.class}: #{e.message}"
            end
            raise
          ensure
            # Reset database session variables
            begin
              connection.execute('RESET tenant_rls.tenant_id') if connection
            rescue
              begin
                connection.execute('RESET application.tenant_id') if connection
              rescue => cleanup_error
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantThread] Failed to reset session variables: #{cleanup_error.message}"
                end
              end
            end

            # Clean up thread-local variables
            TenantRls::Current.reset if defined?(TenantRls::Current)
          end
        end
      end
    end
  end
end
