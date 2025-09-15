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

      # CRITICAL: Determine if we should apply tenant patching at all
      # Only apply to user application code, not system threads
      def should_apply_tenant_patching?
        # Skip if we don't have caller information
        return false unless respond_to?(:caller_locations, true)
        
        caller_locs = caller_locations(1, 10) # Look deeper into call stack
        return false unless caller_locs && !caller_locs.empty?
        
        # SKIP for all system/gem/internal calls
        caller_locs.each do |loc|
          path = loc.path.to_s
          
          # Skip Ruby standard library
          return false if path.include?('/ruby/') && !path.include?('/gems/')
          
          # Skip all gems (including Rails internals, database adapters, etc.)
          return false if path.include?('/gems/')
          
          # Skip Rails internals
          return false if path.include?('/railties/')
          return false if path.include?('/activerecord/')
          return false if path.include?('/activesupport/')
          return false if path.include?('/actionpack/')
          
          # Skip database adapters and connection pools
          return false if path.include?('/pg-')
          return false if path.include?('/mysql')
          return false if path.include?('/sqlite')
          return false if path.include?('/mongo')
          
          # Skip web servers
          return false if path.include?('/puma/')
          return false if path.include?('/unicorn/')
          return false if path.include?('/thin/')
          
          # Skip background job processors  
          return false if path.include?('/sidekiq/')
          return false if path.include?('/resque/')
        end
        
        # Only ALLOW for application code (app/, lib/, config/)
        return caller_locs.any? { |loc| 
          path = loc.path.to_s
          path.include?('/app/') || path.include?('/lib/') || path.include?('/config/')
        }
      end

      # Determine if we should use dedicated connection management
      # True for Puma multi-threaded environments or when explicitly enabled
      def should_use_connection_management?
        return false unless TenantRls.configuration.puma_thread_connection_management
        
        # Detect if running in Puma (multi-threaded server)
        defined?(Puma) || ENV['SERVER_SOFTWARE']&.include?('puma') || 
        (defined?(Rails) && Rails.env.production? && Thread.current.name&.include?('puma'))
      end

      # Create lightweight thread (original behavior)
      def create_lightweight_thread(context, *args, &block)
        new_without_tenant_context(*args) do
          begin
            # Restore tenant context in the new thread
            TenantRls::Current.tenant_id = context[:tenant_id]
            TenantRls::Current.user = context[:user]

            if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
              Rails.logger.debug { "[TenantRls] Lightweight thread: restored tenant_id=#{context[:tenant_id]}" }
            end

            # Execute the original block - Rails will handle DB connections automatically
            yield if block_given?

          rescue => e
            if defined?(Rails) && Rails.logger
              Rails.logger.error "[TenantRls] Error in lightweight Thread.new: #{e.class}: #{e.message}"
              Rails.logger.error "[TenantRls] Backtrace: #{e.backtrace&.first(3)&.join('\n  ')}"
            end
            raise
          ensure
            # Clean up thread-local variables
            TenantRls::Current.reset if defined?(TenantRls::Current)
          end
        end
      end

      # Create thread with dedicated connection management for Puma/long-running tasks
      def create_thread_with_connection_management(context, *args, &block)
        new_without_tenant_context(*args) do
          # Check out a dedicated connection from the pool for this thread
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            begin
              # Restore tenant context in the new thread
              TenantRls::Current.tenant_id = context[:tenant_id]
              TenantRls::Current.user = context[:user]

              # Set tenant context on the database connection (for RLS)
              if context[:tenant_id] && !context[:tenant_id].to_s.strip.empty?
                tenant_column = TenantRls.configuration.tenant_id_column.to_s
                connection.execute("SET session.#{tenant_column} = #{connection.quote(context[:tenant_id])}")
                
                if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                  Rails.logger.debug { "[TenantRls] Puma thread: set #{tenant_column}=#{context[:tenant_id]} on dedicated connection" }
                end
              end

              if TenantRls.is_debugging? && defined?(Rails) && Rails.logger
                Rails.logger.debug { "[TenantRls] Puma thread: using dedicated connection for tenant_id=#{context[:tenant_id]}" }
              end

              # Execute the original block with the dedicated connection
              yield if block_given?

            rescue => e
              if defined?(Rails) && Rails.logger
                Rails.logger.error "[TenantRls] Error in Puma Thread.new: #{e.class}: #{e.message}"
                Rails.logger.error "[TenantRls] Backtrace: #{e.backtrace&.first(3)&.join('\n  ')}"
              end
              raise
            ensure
              # Clean up thread-local variables
              TenantRls::Current.reset if defined?(TenantRls::Current)
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
      class << self
        alias_method :new_without_tenant_context, :new
        alias_method :new, :new_with_tenant_context
      end

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.info '[TenantRls] Automatic Thread.new tenant context preservation enabled (selective patching)'
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
