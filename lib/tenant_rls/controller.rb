module TenantRls
  module Controller
    extend ActiveSupport::Concern
    include TenantRls::TenantContextManager

    included do
      around_action :set_tenant_context
    end

    private
      def set_tenant_context(&block)
        context_data = {
          type: :controller,
          request: request,
          current_user: respond_to?(:current_user) ? current_user : nil,
          current_company: respond_to?(:current_company) ? current_company : nil
        }

        # Supply dynamic current tenant object based on configured tenant key, e.g., current_account
        tenant_object_key = TenantRls.configuration.tenant_object_key
        dynamic_current_method = "current_#{tenant_object_key}"
        if respond_to?(dynamic_current_method)
          context_data["current_#{tenant_object_key}".to_sym] = public_send(dynamic_current_method)
        end
        # Also provide plain tenant object key if controller exposes it directly
        if respond_to?(tenant_object_key)
          context_data[tenant_object_key] = public_send(tenant_object_key)
        end

        execute_with_tenant_context(context_data, &block)
      end

      def build_tenant_context
        strategy = TenantRls.configuration.tenant_resolver_strategy

        case strategy
        when :warden
          build_warden_context
        when :custom_auth
          build_custom_auth_context
        when :job_context
          build_job_context
        when :manual
          build_manual_context
        else
          {}
        end
      end

      def build_warden_context
        { request: request }
      end

      def build_custom_auth_context
        {
          current_user: respond_to?(:current_user) ? current_user : nil,
          current_company: respond_to?(:current_company) ? current_company : nil
        }
      end

      def build_job_context
        {}
      end

      def build_manual_context
        {}
      end

      def extract_user_from_context(context)
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
