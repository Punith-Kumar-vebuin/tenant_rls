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
        raise NotImplementedError, "Subclasses must implement #resolve"
      end
    end
  end

  class WardenResolver < BaseResolver
    class << self
      def resolve(context = {})
        request = context[:request]
        return nil unless request&.env&.dig('warden')

        user = request.env['warden'].user
        user&.companies_users&.first&.company_id
      end
    end
  end

  class CustomAuthResolver < BaseResolver
    class << self
      def resolve(context = {})
        current_company = context[:current_company]
        return nil unless current_company

        current_company.id
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

        if context[:company_id]
          return context[:company_id]
        end

        Rails.logger.warn "[TenantRls] No tenant_id could be resolved from context: #{context.inspect}"
        nil
      end

      private

      def extract_company_id_from_worker_args(args)
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
          company_id = args[:company_id] || args['company_id']
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
          %w(company_id).each do |key|
            [key.to_sym, key.to_s].each do |k|
              if job_data.key?(k) && job_data[k]
                company_id = job_data[k]
                if company_id.is_a?(Integer) && company_id > 0
                  return company_id
                end
              end
            end
          end

          %w(company).each do |key|
            [key.to_sym, key.to_s].each do |k|
              if job_data.key?(k) && job_data[k]
                company_data = job_data[k]
                if company_data.is_a?(Hash)
                  company_id = company_data[:id] || company_data['id']
                  if company_id&.is_a?(Integer) && company_id > 0
                    return company_id
                  end
                end
              end
            end
          end
        end

        if job_data.respond_to?(:company) && job_data.company&.respond_to?(:id)
          company_id = job_data.company.id
          if company_id.is_a?(Integer) && company_id > 0
            return company_id
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
