require 'active_support/concern'

module TenantRls
  module TenantContextManager
    extend ActiveSupport::Concern

    private
      def execute_with_tenant_context(context_data = {}, &block)
        context = build_tenant_context_from_data(context_data)
        tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)
        user = extract_user_from_context_data(context_data, context)
        context_type = determine_context_type(context_data)

        Rails.logger.info "[TenantRls] #{context_type} tenant_id=#{tenant_id.inspect} using strategy=#{TenantRls.configuration.tenant_resolver_strategy}"

        if tenant_id.blank?
          Rails.logger.warn "[TenantRls] WARNING: No tenant_id resolved for #{context_type} - RLS will not be applied!"
        end

        TenantRls::Current.user = user
        TenantRls::Current.tenant_id = tenant_id

        ApplicationRecord.with_tenant(tenant_id) do
          Rails.logger.info "[TenantRls] ▶ SET tenant_rls.tenant_id=#{tenant_id.inspect} for #{context_type}"
          verify_rls_execution(tenant_id) if TenantRls.configuration.debug_logging
          yield
        end
      ensure
        Rails.logger.info "[TenantRls] ◀ RESET tenant_rls.tenant_id=#{tenant_id.inspect} for #{context_type}"
        TenantRls::Current.reset
      end

      def build_tenant_context_from_data(context_data)
        case context_data[:type]
        when :worker
          { worker_perform_args: context_data[:args] }
        when :job
          { job_data: context_data[:data] }
        when :controller
          build_tenant_context_for_controller(context_data)
        when :manual
          { tenant_id: context_data[:tenant_id], user: context_data[:user] }
        else
          if context_data[:args]&.is_a?(Array)
            { worker_perform_args: context_data[:args] }
          elsif context_data[:data]
            { job_data: context_data[:data] }
          else
            context_data
          end
        end
      end

      def extract_user_from_context_data(context_data, resolved_context)
        case context_data[:type]
        when :worker
          extract_user_from_worker_args(context_data[:args])
        when :job
          extract_user_from_job_data(context_data[:data])
        when :controller
          extract_user_from_controller_context(resolved_context)
        when :manual
          context_data[:user]
        else
          if context_data[:args]&.is_a?(Array)
            extract_user_from_worker_args(context_data[:args])
          elsif context_data[:data]
            extract_user_from_job_data(context_data[:data])
          else
            nil
          end
        end
      end

      def determine_context_type(context_data)
        case context_data[:type]
        when :worker then 'Worker'
        when :job then 'Job'
        when :controller then 'Controller'
        when :manual then 'Manual'
        else
          if context_data[:args]&.is_a?(Array)
            'Worker'
          elsif context_data[:data]
            'Job'
          else
            'Unknown'
          end
        end
      end

      def verify_rls_execution(tenant_id)
        return if tenant_id.blank?

        begin
          result = ApplicationRecord.connection.execute('SHOW tenant_rls.tenant_id').first
          current_setting = result['tenant_rls.tenant_id'] if result

          if current_setting.to_s == tenant_id.to_s
            Rails.logger.debug { "[TenantRls] RLS verification passed: PostgreSQL tenant_rls.tenant_id = #{current_setting}" }
          else
            Rails.logger.error "[TenantRls] RLS verification FAILED: Expected #{tenant_id}, got #{current_setting.inspect}"
          end
        rescue => e
          Rails.logger.error "[TenantRls] RLS verification error: #{e.message}"
        end
      end

      def extract_user_from_worker_args(args)
        return nil unless args.is_a?(Array) && args.length >= 2

        notification_data = args[1]
        return nil unless notification_data.is_a?(Hash)

        user_data = notification_data['user'] || notification_data[:user]
        return user_data if user_data

        if notification_data['all_data']
          all_data = notification_data['all_data']
          return all_data['user'] || all_data[:user] if all_data.is_a?(Hash)
        end

        nil
      end

      def extract_user_from_job_data(job_data)
        return nil unless job_data

        if job_data.respond_to?(:user) && job_data.user
          return job_data.user
        end

        if job_data.is_a?(Hash)
          user_data = job_data[:user] || job_data['user']
          return user_data if user_data

          if job_data[:all_data] || job_data['all_data']
            all_data = job_data[:all_data] || job_data['all_data']
            return all_data[:user] || all_data['user'] if all_data.is_a?(Hash)
          end
        end

        nil
      end

      def build_tenant_context_for_controller(context_data)
        strategy = TenantRls.configuration.tenant_resolver_strategy

        case strategy
        when :warden
          { request: context_data[:request] }
        when :custom_auth
          {
            current_user: context_data[:current_user],
            current_company: context_data[:current_company]
          }
        when :manual
          { tenant_id: context_data[:tenant_id], user: context_data[:user] }
        else
          {}
        end
      end

      def extract_user_from_controller_context(context)
        strategy = TenantRls.configuration.tenant_resolver_strategy

        case strategy
        when :warden
          context[:request]&.env&.dig('warden')&.user
        when :custom_auth
          context[:current_user]
        when :job_context
          job_data = context[:job_data]
          return nil unless job_data

          job_data[:user] || job_data['user']
        when :manual
          context[:user]
        else
          nil
        end
      end
  end
end
