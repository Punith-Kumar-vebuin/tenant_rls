module TenantRls
  module Context
    def with_tenant(tenant_id)
      return yield if tenant_id.blank?

      connection.execute("SET tenant_rls.tenant_id = #{connection.quote(tenant_id)}")

      # Minimal enhancement: Don't reset immediately during request context (for helpers/modules)
      if TenantRls::Current.respond_to?(:in_request_context?) && TenantRls::Current.in_request_context?
        yield
        # Don't reset here - let the controller manage cleanup at end of request
      else
        # Original behavior for non-request contexts (jobs, manual calls)
        begin
          yield
        ensure
          connection.execute('RESET tenant_rls.tenant_id')
        end
      end
    end

    def current_tenant_id
      connection.execute('SHOW tenant_rls.tenant_id').getvalue(0, 0)
    end
  end
end
