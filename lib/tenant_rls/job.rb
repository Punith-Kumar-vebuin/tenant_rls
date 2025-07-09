module TenantRls
  module Job
    extend ActiveSupport::Concern
    include TenantRls::TenantContextManager

    included do
      if defined?(Sidekiq) && respond_to?(:sidekiq_options)
        prepend SidekiqWorkerPatch
      end

      if defined?(ActiveJob) && self < ActiveJob::Base
        around_perform :around_perform_with_tenant_context
      end
    end

    module SidekiqWorkerPatch
      def perform(*args)
        if self.class.to_s.match?(/Job/i)
          Rails.logger.debug { "[TenantRls] Sidekiq worker perform called with args: #{args.inspect}" }
          around_perform_with_tenant_context(*args) do
            super(*args)
          end
        else
          Rails.logger.debug { "[TenantRls] Sidekiq worker perform called with args: #{args.inspect}" }
          execute_with_tenant_context(type: :worker, args: args) do
            super(*args)
          end
        end
      end
    end

    def around_perform_with_tenant_context(*args, &block)
      Rails.logger.debug { "[TenantRls] Job perform called with args: #{args.inspect}" }

      job_data = args.first
      if respond_to?(:from_job_data) && job_data
        begin
          parsed_data = from_job_data(job_data)
          Rails.logger.debug { "[TenantRls] Parsed job data using from_job_data: #{parsed_data.class}" }
        rescue => e
          Rails.logger.warn "[TenantRls] Failed to parse job data with from_job_data: #{e.message}"
          parsed_data = job_data
        end
      else
        parsed_data = job_data
      end

      execute_with_tenant_context(type: :job, data: parsed_data) do
        yield
      end
    end

    def with_tenant_context_for_worker(*args, &block)
      execute_with_tenant_context(type: :worker, args: args, &block)
    end

    def with_tenant_context_for_job(job_data, &block)
      execute_with_tenant_context(type: :job, data: job_data, &block)
    end

    def with_tenant_context(job_data = {}, &block)
      Rails.logger.warn '[TenantRls] Using legacy with_tenant_context method - consider upgrading to new API'
      execute_with_tenant_context(type: :job, data: job_data, &block)
    end

    def tenant_from_job_data(job_data)
      Rails.logger.warn '[TenantRls] Using legacy tenant_from_job_data method - consider upgrading to new API'

      context = { job_data: job_data }
      tenant_id = TenantRls::TenantResolver.resolve_tenant_id(context)

      TenantRls::Current.user = extract_user_from_job_data(job_data)
      TenantRls::Current.tenant_id = tenant_id

      if tenant_id.present?
        ApplicationRecord.connection.execute("SET tenant_rls.tenant_id = #{ApplicationRecord.connection.quote(tenant_id)}")
        Rails.logger.info "[TenantRls] ▶ SET tenant_rls.tenant_id=#{tenant_id.inspect} for job session (legacy)"
      else
        Rails.logger.warn '[TenantRls] No tenant_id to set for legacy job session'
      end
    end

    def reset_tenant_context
      Rails.logger.warn '[TenantRls] Using legacy reset_tenant_context method - consider upgrading to new API'
      ApplicationRecord.connection.execute('RESET tenant_rls.tenant_id')
      TenantRls::Current.reset
      Rails.logger.info '[TenantRls] ◀ RESET tenant_rls.tenant_id for job session (legacy)'
    end

    def debug_tenant_context(message = 'Debug')
      tenant_id = TenantRls::Current.tenant_id
      user = TenantRls::Current.user

      Rails.logger.info "[TenantRls] #{message}: tenant_id=#{tenant_id.inspect}, user=#{user.inspect}"

      if tenant_id.present?
        begin
          result = ApplicationRecord.connection.execute('SHOW tenant_rls.tenant_id').first
          pg_setting = result['tenant_rls.tenant_id'] if result
          Rails.logger.info "[TenantRls] PostgreSQL setting: tenant_rls.tenant_id=#{pg_setting.inspect}"

          if pg_setting.to_s != tenant_id.to_s
            Rails.logger.error "[TenantRls] MISMATCH: Current=#{tenant_id}, PostgreSQL=#{pg_setting}"
          end
        rescue => e
          Rails.logger.error "[TenantRls] Error checking PostgreSQL setting: #{e.message}"
        end
      end

      { tenant_id: tenant_id, user: user, postgresql_setting: pg_setting }
    end

    private
      def extract_user_from_worker_context(args)
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
  end
end
