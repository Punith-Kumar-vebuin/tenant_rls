module TenantRls
  module Context
    def with_tenant(tenant_id)
      return yield if tenant_id.blank?

      connection.execute("SET tenant_rls.tenant_id = #{connection.quote(tenant_id)}")
      yield
    ensure
      connection.execute('RESET tenant_rls.tenant_id')
    end

    def current_tenant_id
      connection.execute('SHOW tenant_rls.tenant_id').getvalue(0, 0)
    end
  end
end
