require 'tenant_rls/configuration'
require 'tenant_rls/tenant_resolver'
require 'tenant_rls/tenant_context_manager'
require 'tenant_rls/controller'
require 'tenant_rls/job'
require 'tenant_rls/context'
require 'tenant_rls/current'

module TenantRls
  class Railtie < ::Rails::Railtie
    initializer 'tenant_rls.action_controller' do
      ActiveSupport.on_load(:action_controller) do
        include TenantRls::Controller
      end
      ActiveSupport.on_load(:action_controller_api) do
        include TenantRls::Controller
      end
    end

    initializer 'tenant_rls.active_record' do
      ActiveSupport.on_load(:active_record) do
        extend TenantRls::Context
      end
    end

    initializer 'tenant_rls.active_job' do
      ActiveSupport.on_load(:active_job) do
        include TenantRls::Job
      end
    end

    config.before_configuration do
      TenantRls.configure do |config|
        config.tenant_resolver_strategy = :warden
        config.tenant_id_column = :company_id
        config.debug_logging = Rails.env.development?
      end
    end
  end
end
