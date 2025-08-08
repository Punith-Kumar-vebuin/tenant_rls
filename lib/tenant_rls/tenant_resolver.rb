module TenantRls
  class TenantResolver
    class << self
      def resolve_tenant_id(context = {})
        strategy = TenantRls.configuration.tenant_resolver_strategy
        resolver = resolver_for_strategy(strategy)
        tenant_id = resolver.resolve(context)

        Rails.logger.info "[TenantRls] Resolved tenant_id=#{tenant_id.inspect} using strategy=#{strategy}" if TenantRls.configuration.debug_logging
        tenant_id
      end

      private
        def resolver_for_strategy(strategy)
          case strategy
          when :warden then WardenResolver
          when :custom_auth then CustomAuthResolver
          when :job_context then JobContextResolver
          when :manual then ManualResolver
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
        request = context[:request]
        return nil unless request&.env&.dig('warden')

        user = request.env['warden'].user
        return nil unless user

        tenant_id_column = TenantRls.configuration.tenant_id_column.to_sym
        tenant_object_key = TenantRls.configuration.tenant_object_key

        # 1) Direct attribute on user, e.g., user.account_id
        if user.respond_to?(tenant_id_column)
          value = user.public_send(tenant_id_column)
          return value if value.is_a?(Integer) && value > 0
        end

        # 2) Through associated tenant object, e.g., user.account.id
        if user.respond_to?(tenant_object_key)
          tenant_object = user.public_send(tenant_object_key)
          if tenant_object && tenant_object.respond_to?(:id)
            value = tenant_object.id
            return value if value.is_a?(Integer) && value > 0
          end
        end

        # 3) Through join association, e.g., user.accounts_users.first.account_id
        join_assoc = "#{tenant_object_key}s_users"
        if user.respond_to?(join_assoc)
          record = Array(user.public_send(join_assoc)).first
          if record && record.respond_to?(tenant_id_column)
            value = record.public_send(tenant_id_column)
            return value if value.is_a?(Integer) && value > 0
          end
        end

        # 4) Backward compatibility for company-based schemas
        user&.companies_users&.first&.company_id
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
        return nil if context.blank?

        if context[:worker_perform_args]
          tenant_id = extract_company_id_from_worker_args(context[:worker_perform_args])
          return tenant_id if tenant_id
        end

        if context[:job_data]
          tenant_id = extract_company_id_from_job_data(context[:job_data])
          return tenant_id if tenant_id
        end

        # Directly provided configured tenant id column in context
        tenant_id_column = TenantRls.configuration.tenant_id_column.to_sym
        if context.key?(tenant_id_column)
          value = context[tenant_id_column]
          return value if value.is_a?(Integer) && value.positive?
        end

        Rails.logger.warn "[TenantRls] No tenant_id could be resolved from context: #{context.inspect}"
        nil
      end

      private
        def extract_company_id_from_worker_args(args)
          # Heuristics for worker args stay positional and hash-based for compatibility
          return nil unless args

          if args.is_a?(Array) && !args.empty?
            last_arg = args.last
            if last_arg.is_a?(Integer) && last_arg > 0
              return last_arg
            end

            if args.length >= 2
              second_last = args[-2]
              if second_last.is_a?(Integer) && second_last > 0
                return second_last
              end
            end
          end

          if args.is_a?(Hash)
            tenant_id_column = TenantRls.configuration.tenant_id_column
            company_id = args[tenant_id_column] || args[tenant_id_column.to_s]
            if company_id&.is_a?(Integer) && company_id > 0
              return company_id
            end
          end

          nil
        end

        def extract_company_id_from_job_data(job_data)
          return nil unless job_data

          if job_data.is_a?(String)
            begin
              parsed_data = JSON.parse(job_data)
              return extract_company_id_from_job_data(parsed_data)
            rescue JSON::ParserError => e
              Rails.logger.error "[TenantRls] JSON parsing failed for job data: #{e.message}"
              return nil
            end
          end

          if job_data.is_a?(Hash)
            tenant_id_column = TenantRls.configuration.tenant_id_column
            tenant_object_key = TenantRls.configuration.tenant_object_key

            # Direct tenant id column
            if job_data.key?(tenant_id_column) || job_data.key?(tenant_id_column.to_s)
              value = job_data[tenant_id_column] || job_data[tenant_id_column.to_s]
              return value if value.is_a?(Integer) && value.positive?
            end

            # Nested tenant object by configured key
            if job_data.key?(tenant_object_key) || job_data.key?(tenant_object_key.to_s)
              tenant_obj = job_data[tenant_object_key] || job_data[tenant_object_key.to_s]
              if tenant_obj.is_a?(Hash)
                value = tenant_obj[:id] || tenant_obj['id']
                return value if value.is_a?(Integer) && value.positive?
              elsif tenant_obj.is_a?(Integer)
                return tenant_obj if tenant_obj.positive?
              end
            end

            # Backward compatibility for company key
            if job_data.key?(:company) || job_data.key?('company')
              company_data = job_data[:company] || job_data['company']
              if company_data.is_a?(Hash)
                company_id = company_data[:id] || company_data['id']
                return company_id if company_id.is_a?(Integer) && company_id.positive?
              end
            end
          end

          # Deep object access: prefer configured accessor; fallback to company
          tenant_object_key = TenantRls.configuration.tenant_object_key
          if job_data.respond_to?(tenant_object_key)
            tenant_obj = job_data.public_send(tenant_object_key)
            if tenant_obj && tenant_obj.respond_to?(:id)
              value = tenant_obj.id
              return value if value.is_a?(Integer) && value.positive?
            end
          elsif job_data.respond_to?(:company)
            company = job_data.company
            if company && company.respond_to?(:id)
              value = company.id
              return value if value.is_a?(Integer) && value.positive?
            end
          end

          nil
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
end
