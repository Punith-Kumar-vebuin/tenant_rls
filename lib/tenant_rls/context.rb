module TenantRls
  module Context
    def with_tenant(tenant_id)
      return yield if tenant_id.blank?

      connection.execute("SET tenant_rls.tenant_id = #{connection.quote(tenant_id)}")
      yield
    ensure
      connection.execute('RESET tenant_rls.tenant_id')
    end
  end
end
