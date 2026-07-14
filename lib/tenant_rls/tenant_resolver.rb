module TenantRls
  class TenantResolver
    class << self
      def resolve_tenant_id(context = {})
        strategy = TenantRls.configuration.tenant_resolver_strategy
        resolver = resolver_for_strategy(strategy)
        tenant_id = resolver.resolve(context)

        if TenantRls.is_debugging?
          Rails.logger.info { "[TenantRls] Resolved tenant_id=#{tenant_id.inspect} using strategy=#{strategy}" }
        end
        tenant_id
      end

      private
        def resolver_for_strategy(strategy)
          case strategy
          when :warden then WardenResolver
          when :custom_auth then CustomAuthResolver
          when :job_context then JobContextResolver
          when :manual then ManualResolver
          when :hybrid then HybridResolver
          else
            raise ArgumentError, "Unknown tenant resolver strategy: #{strategy}"
          end
        end
    end
  end

  class BaseResolver
    class << self
      def resolve(context = {})
        raise NotImplementedError, 'Subclasses must implement #resolve'
      end
    end
  end

  class WardenResolver < BaseResolver
    class << self
      def resolve(context = {})
        # Fast path: early return for invalid context
        request = context[:request]
        return nil unless request&.env&.dig('warden')

        user = request.env['warden'].user
        return nil unless user

        # Cache configuration access for performance
        tenant_id_column = TenantRls.configuration.tenant_id_column

        # 1) Fast path: Direct attribute on user (most common case)
        if user.respond_to?(tenant_id_column)
          value = user.public_send(tenant_id_column)
          return value if value.is_a?(Integer) && value > 0
        end

        # 2) Optimized: Use memoized tenant_object_key
        tenant_object_key = tenant_object_key_for_column(tenant_id_column)

        # Try associated tenant object
        if user.respond_to?(tenant_object_key)
          tenant_object = user.public_send(tenant_object_key)
          if tenant_object&.respond_to?(:id)
            value = tenant_object.id
            return value if value.is_a?(Integer) && value > 0
          end
        end

        # 3) Optimized join association lookup
        join_assoc = join_association_for_key(tenant_object_key)
        if user.respond_to?(join_assoc)
          record = user.public_send(join_assoc)&.first
          if record&.respond_to?(tenant_id_column)
            value = record.public_send(tenant_id_column)
            return value if value.is_a?(Integer) && value > 0
          end
        end

        # 4) Fast backward compatibility (cached check)
        legacy_company_id(user)
      end

      private

      def tenant_object_key_for_column(tenant_id_column)
        # Memoized conversion: :company_id => :company
        @tenant_object_keys ||= {}
        @tenant_object_keys[tenant_id_column] ||=
          tenant_id_column.to_s.end_with?('_id') ?
          tenant_id_column.to_s.sub(/_id\z/, '').to_sym :
          tenant_id_column
      end

      def join_association_for_key(tenant_object_key)
        # Memoized join association: :company => :companies_users
        @join_associations ||= {}
        @join_associations[tenant_object_key] ||= "#{tenant_object_key}s_users".to_sym
      end

      def legacy_company_id(user)
        # Optimized legacy path with early returns
        return nil unless user.respond_to?(:companies_users)
        companies_users = user.companies_users
        return nil unless companies_users&.any?
        companies_users.first&.company_id
      end
    end
  end

  class CustomAuthResolver < BaseResolver
    class << self
      def resolve(context = {})
        tenant_id_column = TenantRls.configuration.tenant_id_column.to_sym
        tenant_object_key = TenantRls.configuration.tenant_object_key

        # 1) If context directly provides the tenant id column
        if context.key?(tenant_id_column)
          value = context[tenant_id_column]
          return value if value.is_a?(Integer) && value > 0
        end
        string_key = tenant_id_column.to_s
        if context.key?(string_key)
          value = context[string_key]
          return value if value.is_a?(Integer) && value > 0
        end

        # 2) If context provides a tenant object using configured key
        tenant_obj = context[tenant_object_key] || context[tenant_object_key.to_s]
        if tenant_obj
          if tenant_obj.is_a?(Integer)
            return tenant_obj if tenant_obj > 0
          elsif tenant_obj.respond_to?(:id)
            value = tenant_obj.id
            return value if value.is_a?(Integer) && value > 0
          end
        end

        # 3) Backward compatibility for current_company
        current_company = context[:current_company] || context['current_company']
        if current_company && current_company.respond_to?(:id)
          value = current_company.id
          return value if value.is_a?(Integer) && value > 0
        end

        nil
      end
    end
  end

  class JobContextResolver < BaseResolver
    class << self
      def resolve(context = {})
        # Fast path: early return for empty context
        return nil if context.blank?

        # Priority 1: Worker args (most common for Sidekiq workers)
        if context[:worker_perform_args]
          tenant_id = extract_tenant_from_worker_args(context[:worker_perform_args])
          return tenant_id if tenant_id
        end

        # Priority 2: Job data (ActiveJob and complex payloads)
        if context[:job_data]
          tenant_id = extract_tenant_from_job_data(context[:job_data])
          return tenant_id if tenant_id
        end

        # Priority 3: Direct context key (manual/testing)
        tenant_id_column = TenantRls.configuration.tenant_id_column
        if context.key?(tenant_id_column)
          value = context[tenant_id_column]
          return value if value.is_a?(Integer) && value > 0
        end

        # Only log in debug mode to avoid noise
        if TenantRls.is_debugging?
          Rails.logger.debug { '[TenantRls] No tenant_id resolved from job context' }
        end
        nil
      end

      private
        def extract_tenant_from_worker_args(args)
          # Backward compatibility: support hash-based worker args
          if args.is_a?(Hash)
            tenant_id_column = TenantRls.configuration.tenant_id_column
            value = args[tenant_id_column] || args[tenant_id_column.to_s]
            return value if value.is_a?(Integer) && value > 0
            return nil
          end

          # Optimized: Fast scanning for tenant IDs in worker arguments
          return nil unless args.is_a?(Array) && !args.empty?

          # Fast path: scan for integers (most common pattern)
          args.reverse_each do |arg|
            return arg if arg.is_a?(Integer) && arg > 0
          end

          # Slower path: check hash arguments for configured column
          tenant_id_column = TenantRls.configuration.tenant_id_column
          args.each do |arg|
            next unless arg.is_a?(Hash)
            value = arg[tenant_id_column] || arg[tenant_id_column.to_s]
            return value if value.is_a?(Integer) && value > 0
          end

          nil
        end

        def extract_tenant_from_job_data(job_data)
          return nil unless job_data

          # Fast path: handle string JSON data
          if job_data.is_a?(String)
            parsed_data = parse_json_safely(job_data)
            return extract_tenant_from_job_data(parsed_data) if parsed_data
            return nil
          end

          # Optimized hash processing
          if job_data.is_a?(Hash)
            return extract_tenant_from_hash(job_data)
          end

          # Object-based data (DeepHashie, etc.)
          extract_tenant_from_object(job_data)
        end

        def parse_json_safely(json_string)
          JSON.parse(json_string)
        rescue JSON::ParserError => e
          if TenantRls.is_debugging?
            Rails.logger.debug { "[TenantRls] JSON parsing failed: #{e.message}" }
          end
          nil
        end

        def extract_tenant_from_hash(job_data)
          tenant_id_column = TenantRls.configuration.tenant_id_column

          # Priority 1: Direct tenant id column (fastest)
          value = job_data[tenant_id_column] || job_data[tenant_id_column.to_s]
          return value if value.is_a?(Integer) && value > 0

          # Priority 2: Nested tenant object by configured key
          tenant_object_key = tenant_object_key_for_column(tenant_id_column)
          tenant_obj = job_data[tenant_object_key] || job_data[tenant_object_key.to_s]

          if tenant_obj
            if tenant_obj.is_a?(Integer) && tenant_obj > 0
              return tenant_obj
            elsif tenant_obj.is_a?(Hash)
              id_value = tenant_obj[:id] || tenant_obj['id']
              return id_value if id_value.is_a?(Integer) && id_value > 0
            end
          end

          # Priority 3: Legacy company key support
          extract_legacy_company_from_hash(job_data)
        end

        def extract_tenant_from_object(job_data)
          # Default pick first arg
          return job_data if job_data.is_a?(Integer) && job_data > 0

          tenant_object_key = tenant_object_key_for_column(TenantRls.configuration.tenant_id_column)

          # Try configured accessor first
          if job_data.respond_to?(tenant_object_key)
            tenant_obj = job_data.public_send(tenant_object_key)
            if tenant_obj&.respond_to?(:id)
              value = tenant_obj.id
              return value if value.is_a?(Integer) && value > 0
            end
          end

          # Legacy company fallback
          if job_data.respond_to?(:company)
            company = job_data.company
            if company&.respond_to?(:id)
              value = company.id
              return value if value.is_a?(Integer) && value > 0
            end
          end

          nil
        end

        def extract_legacy_company_from_hash(job_data)
          company_data = job_data[:company] || job_data['company']
          return nil unless company_data.is_a?(Hash)

          company_id = company_data[:id] || company_data['id']
          company_id if company_id.is_a?(Integer) && company_id > 0
        end

        def tenant_object_key_for_column(tenant_id_column)
          # Memoized conversion for performance
          @tenant_object_keys ||= {}
          @tenant_object_keys[tenant_id_column] ||=
            tenant_id_column.to_s.end_with?('_id') ?
            tenant_id_column.to_s.sub(/_id\z/, '').to_sym :
            tenant_id_column
        end
    end
  end

  class ManualResolver < BaseResolver
    class << self
      def resolve(context = {})
        context[:tenant_id]
      end
    end
  end

  class HybridResolver < BaseResolver
    class << self
      def resolve(context = {})
        # Optimized hybrid resolution: Warden first, then Sidekiq
        if TenantRls.is_debugging?
          Rails.logger.debug { '[TenantRls] HybridResolver: Starting resolution' }
        end

        # Priority 1: Try Warden first (fast web request detection)
        if has_warden_context?(context)
          if TenantRls.is_debugging?
            Rails.logger.debug { '[TenantRls] HybridResolver: Using Warden strategy' }
          end
          tenant_id = WardenResolver.resolve(context)
          return tenant_id if tenant_id
        end

        # Priority 2: Try Sidekiq context (job processing)
        if has_sidekiq_context?(context)
          if TenantRls.is_debugging?
            Rails.logger.debug { '[TenantRls] HybridResolver: Using Sidekiq strategy' }
          end
          return resolve_sidekiq_context(context)
        end

        # Priority 3: Fast fallback based on context data
        resolve_with_minimal_fallback(context)
      end

      private
        def has_warden_context?(context)
          # Fast check for Warden context
          context[:request] &&
          context[:request].respond_to?(:env) &&
          context[:request].env&.dig('warden')
        end

        def has_sidekiq_context?(context)
          # Fast check for Sidekiq context using safe thread variables
          TenantRls::Job::ThreadContextManager.in_sidekiq_context? ||
          context[:worker_perform_args] ||
          context[:job_data]
        end

        def resolve_sidekiq_context(context)
          # Optimized Sidekiq resolution with direct extraction first
          if context[:worker_perform_args]
            direct_tenant_id = extract_direct_tenant_id_from_args(context[:worker_perform_args])
            return direct_tenant_id if direct_tenant_id
          end

          # Use standard job context resolution
          JobContextResolver.resolve(context)
        end

        def resolve_with_minimal_fallback(context)
          if TenantRls.is_debugging?
            Rails.logger.debug { '[TenantRls] HybridResolver: Minimal fallback resolution' }
          end

          # Try job context if any job-related data exists
          if context[:worker_perform_args] || context[:job_data]
            tenant_id = JobContextResolver.resolve(context)
            return tenant_id if tenant_id
          end

          # Try Warden without strict context check (fallback)
          tenant_id = WardenResolver.resolve(context)
          return tenant_id if tenant_id

          # Last resort: manual
          ManualResolver.resolve(context)
        end

        def extract_direct_tenant_id_from_args(args)
          # Optimized: Extract tenant_id directly from perform args (fast path)
          return nil unless args.is_a?(Array) && !args.empty?

          tenant_id_column = TenantRls.configuration.tenant_id_column

          # Scan arguments efficiently for potential tenant IDs
          args.each do |arg|
            if arg.is_a?(Integer) && arg > 0
              if TenantRls.is_debugging?
                Rails.logger.debug { "[TenantRls] HybridResolver: Found direct tenant_id: #{arg}" }
              end
              return arg
            elsif arg.is_a?(Hash)
              # Check for configured tenant id column
              value = arg[tenant_id_column] || arg[tenant_id_column.to_s]
              return value if value.is_a?(Integer) && value > 0
            end
          end

          nil
        end
    end
  end
end
