module TenantRls
  module Controller
    extend ActiveSupport::Concern
    include TenantRls::TenantContextManager

    included do
      around_action :set_tenant_context
    end

    private
      def set_tenant_context(&block)
        # Minimal addition: Mark that we're in a request context for helpers/modules
        TenantRls::Current.set_request_context!

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
      ensure
        # Minimal addition: Clear request context at end of request
        TenantRls::Current.clear_request_context!
      end
  end
end
