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
      # Skips patching for Ruby internal library calls to avoid interference
      #
      # @param args [Array] Arguments passed to original Thread.new
      # @yield Block to execute in new thread with tenant context preserved
      # @return [Thread] The created thread with tenant context
      def new_with_tenant_context(*args, &block)
        begin
          # EMERGENCY DISABLE: Skip all patching if emergency flag is set
          if TenantRls.configuration.emergency_disable_thread_patching
            return new_without_tenant_context(*args, &block)
          end

          # CRITICAL: Be very selective about when to apply tenant patching
          # Only apply to user application code, not system/gem threads
          unless should_apply_tenant_patching?
            return new_without_tenant_context(*args, &block)
          end

          # Check if we have tenant context to preserve
          tenant_id = TenantRls::Current.tenant_id
          if tenant_id && tenant_id != '' && tenant_id.to_s.strip != ''
            # Capture current context before thread creation
            context = TenantRls::ThreadContextManager.capture_current_context

            if TenantRls.is_debugging?
              Rails.logger.debug { "[TenantRls] Auto-capturing tenant context for Thread.new: tenant_id=#{context[:tenant_id]}" }
            end

            # Create thread with automatic tenant context restoration
            # Handle both lightweight and Puma long-running thread scenarios
            if should_use_connection_management?
              # PUMA MODE: Dedicated connection for long-running threads
              create_thread_with_connection_management(context, *args, &block)
            else
              # LIGHTWEIGHT MODE: Let Rails handle connections per operation
              create_lightweight_thread(context, *args, &block)
            end
          else
            # No tenant context, use original Thread.new behavior
            new_without_tenant_context(*args, &block)
          end
        rescue => e
          # If our patching fails for any reason, fall back to original behavior
          # This ensures Ruby's internal operations always work
          if defined?(Rails) && Rails.logger
            Rails.logger.error "[TenantRls] Thread.new patching failed, falling back to original: #{e.class}: #{e.message}"
          end
          new_without_tenant_context(*args, &block)
        end
      end

      private

      # BULLETPROOF: Only apply tenant patching to YOUR application code
      # Completely avoids Puma, system threads, and all gem code
      def should_apply_tenant_patching?
        return false unless respond_to?(:caller_locations, true)

        caller_locs = caller_locations(1, 15) # Look deeper to catch all system calls
        return false unless caller_locs.present? && !caller_locs.empty?

        # ULTRA-STRICT filtering - if ANY caller is system/gem code, skip entirely
        caller_locs.each do |loc|
          path = loc.path.to_s

          # Skip Ruby standard library completely
          return false if path.include?('/ruby/')

          # Skip ALL gems and vendor code (Rails, Puma, etc.)
          return false if path.include?('/gems/')
          return false if path.include?('/vendor/')
          return false if path.include?('.bundle/')

          # Skip Rails framework directories
          return false if path.include?('/railties/')
          return false if path.include?('/activerecord/')
          return false if path.include?('/activesupport/')
          return false if path.include?('/actionpack/')
          return false if path.include?('/actionview/')
          return false if path.include?('/activejob/')
          return false if path.include?('/actioncable/')
          return false if path.include?('/actionmailer/')

          # Skip ALL web servers (Puma is critical here)
          return false if path.include?('/puma/')
          return false if path.include?('/unicorn/')
          return false if path.include?('/thin/')
          return false if path.include?('/passenger/')
          return false if path.include?('/webrick/')

          # Skip ALL database adapters and MongoDB
          return false if path.include?('/pg-')
          return false if path.include?('/mysql')
          return false if path.include?('/sqlite')
          return false if path.include?('/mongo')
          return false if path.include?('/redis/')

          # Skip ALL background job processors
          return false if path.include?('/sidekiq/')
          return false if path.include?('/resque/')
          return false if path.include?('/delayed_job/')
          return false if path.include?('/good_job/')

          # Skip system and boot files
          return false if path.include?('/bootsnap/')
          return false if path.include?('/spring/')
          return false if path.include?('/zeitwerk/')

          # Skip any path that looks like a gem (contains version numbers)
          return false if path.match?(/\/\w+-[\d.]+\//)
        end

        # WHITELIST APPROACH: Only allow YOUR application directories
        # This ensures only your custom Thread.new calls are affected
        app_paths = caller_locs.any? do |loc|
          path = loc.path.to_s
          # Must be in your application directories
          path.include?('/app/') ||
          path.include?('/lib/') ||
          (path.include?('/config/') && !path.include?('boot.rb'))
        end

        # Additional safety: ensure we're not in any server/system context
        if app_paths
          # Double-check thread name doesn't suggest system thread
          thread_name = Thread.current.name.to_s.downcase
          return false if thread_name.include?('puma')
          return false if thread_name.include?('server')
          return false if thread_name.include?('pool')
          return false if thread_name.include?('worker')
          return false if thread_name.include?('job')
        end

        app_paths
      end

      # Determine if we should use dedicated connection management
      # True for server environments, file operations, or when explicitly enabled
      def should_use_connection_management?
        # Always use connection management if explicitly enabled
        return true if TenantRls.configuration.puma_thread_connection_management

        # CRITICAL: Auto-detect server environments that need connection management
        server_environment = defined?(Puma) ||
                            ENV['SERVER_SOFTWARE']&.include?('puma') ||
                            ENV['RAILS_ENV'] == 'production' ||
                            ENV['RAILS_ENV'] == 'staging' ||
                            !Rails.env.development?

        # CRITICAL: Detect long-running operations (file exports, etc.)
        caller_stack = caller_locations(1, 10).map(&:path).join(' ')
        long_running_operation = caller_stack.include?('export') ||
                                caller_stack.include?('upload') ||
                                caller_stack.include?('process_') ||
                                caller_stack.include?('generate')

        # Use connection management for server environments OR long-running operations
        server_environment || long_running_operation
      end

      # Create lightweight thread (IMPROVED: Forced single connection)
      def create_lightweight_thread(context, *args, &block)
        new_without_tenant_context(*args) do
          # CRITICAL: Use dedicated connection and FORCE all AR operations to use it
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            begin
              # Restore tenant context in the new thread (thread-local variables)
              TenantRls::Current.tenant_id = context[:tenant_id]
              TenantRls::Current.user = context[:user]

              if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                Rails.logger.debug { "[TenantRls] Thread: using dedicated connection for tenant_id=#{context[:tenant_id]}" }
              end

              # CRITICAL: Set database session variable for RLS on the dedicated connection
              if context[:tenant_id] && !context[:tenant_id].to_s.strip.empty?
                connection.execute("SET tenant_rls.tenant_id = #{connection.quote(context[:tenant_id])}")

                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantRls] Thread: SET tenant_rls.tenant_id=#{context[:tenant_id]} on connection #{connection.object_id}" }
                end
              end

              # CRITICAL: Force ActiveRecord to use our specific connection for ALL operations
              # This prevents issues with connection.cache getting different connections
              Thread.current[:tenant_rls_forced_connection] = connection

              # Monkey patch ActiveRecord::Base.connection for this thread only
              original_connection_method = ActiveRecord::Base.method(:connection)
              ActiveRecord::Base.define_singleton_method(:connection) do
                Thread.current[:tenant_rls_forced_connection] || original_connection_method.call
              end

              if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                Rails.logger.debug { "[TenantRls] Thread: Forced all ActiveRecord operations to use connection #{connection.object_id}" }
              end

              # Execute the original block - ALL database operations will use our connection
              yield if block_given?

            rescue => e
              if defined?(Rails) && Rails.logger
                Rails.logger.error "[TenantRls] Error in lightweight Thread.new: #{e.class}: #{e.message}"
                Rails.logger.error "[TenantRls] Backtrace: #{e.backtrace&.first(3)&.join('\n  ')}"
              end
              raise
            ensure
              # Clean up the forced connection
              Thread.current[:tenant_rls_forced_connection] = nil

              # Restore original connection method
              begin
                ActiveRecord::Base.define_singleton_method(:connection, original_connection_method) if original_connection_method
              rescue => method_error
                # Log but don't fail
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantRls] Failed to restore original connection method: #{method_error.message}"
                end
              end

              # Clean up thread-local variables
              TenantRls::Current.reset if defined?(TenantRls::Current)

              # CRITICAL: Reset database session variable on the SAME connection
              begin
                connection.execute('RESET tenant_rls.tenant_id') if connection
                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantRls] Thread cleanup: RESET tenant_rls.tenant_id on connection #{connection.object_id}" }
                end
              rescue => cleanup_error
                # Log but don't raise - we're in cleanup
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantRls] Failed to reset database session in thread cleanup: #{cleanup_error.message}"
                end
              end
            end
          end
        end
      end

      # Create thread with dedicated connection management for Puma/long-running tasks
      def create_thread_with_connection_management(context, *args, &block)
        new_without_tenant_context(*args) do
          # Check out a dedicated connection from the pool for this thread
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            begin
              # Restore tenant context in the new thread (thread-local variables)
              TenantRls::Current.tenant_id = context[:tenant_id]
              TenantRls::Current.user = context[:user]

              # CRITICAL: Set database session variable for RLS on the dedicated connection
              if context[:tenant_id] && !context[:tenant_id].to_s.strip.empty?
                connection.execute("SET tenant_rls.tenant_id = #{connection.quote(context[:tenant_id])}")

                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantRls] Puma thread: SET tenant_rls.tenant_id=#{context[:tenant_id]} on connection #{connection.object_id}" }
                end
              end

              # CRITICAL: Force ActiveRecord to use our specific connection for ALL operations
              Thread.current[:tenant_rls_forced_connection] = connection
              original_connection_method = ActiveRecord::Base.method(:connection)
              ActiveRecord::Base.define_singleton_method(:connection) do
                Thread.current[:tenant_rls_forced_connection] || original_connection_method.call
              end

              # Execute the original block with forced single connection
              yield if block_given?

            rescue => e
              if defined?(Rails) && Rails.logger
                Rails.logger.error "[TenantRls] Error in Puma Thread.new: #{e.class}: #{e.message}"
                Rails.logger.error "[TenantRls] Backtrace: #{e.backtrace&.first(3)&.join('\n  ')}"
              end
              raise
            ensure
              # Clean up the forced connection
              Thread.current[:tenant_rls_forced_connection] = nil

              # Restore original connection method
              begin
                ActiveRecord::Base.define_singleton_method(:connection, original_connection_method) if original_connection_method
              rescue => method_error
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantRls] Failed to restore original connection method: #{method_error.message}"
                end
              end

              # Clean up thread-local variables
              TenantRls::Current.reset if defined?(TenantRls::Current)

              # CRITICAL: Reset database session variable on the same connection
              begin
                connection.execute('RESET tenant_rls.tenant_id') if connection
                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantRls] Puma thread cleanup: RESET tenant_rls.tenant_id on connection #{connection.object_id}" }
                end
              rescue => cleanup_error
                # Log but don't raise - we're in cleanup
                if defined?(Rails) && Rails.logger
                  Rails.logger.warn "[TenantRls] Failed to reset database session in Puma thread cleanup: #{cleanup_error.message}"
                end
              end
            end
          end
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
    if TenantRls.configuration.auto_thread_tenant_context &&
       !TenantRls.configuration.emergency_disable_thread_patching

      # CRITICAL: Guard against double-patching in server environments
      # Check if we've already patched Thread.new to avoid duplicate execution
      unless Thread.respond_to?(:new_without_tenant_context)
        class << self
          alias_method :new_without_tenant_context, :new
          alias_method :new, :new_with_tenant_context
        end

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.info '[TenantRls] Thread.new tenant context preservation enabled (first time)'
        end
      else
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn '[TenantRls] Thread.new already patched - skipping duplicate patching (this prevents double execution)'
        end
      end

    elsif TenantRls.configuration.emergency_disable_thread_patching
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn '[TenantRls] Thread.new patching DISABLED by emergency_disable_thread_patching flag'
      end
    end
  rescue => e
    # If configuration fails during initialization, log and continue without patching
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.error "[TenantRls] Failed to enable auto Thread.new patching: #{e.message}"
    end
  end
end
