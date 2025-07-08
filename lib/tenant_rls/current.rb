module TenantRls
  class Current
    class << self
      def user=(val)
        Thread.current[:tenant_rls_user] = val
      end

      def user
        Thread.current[:tenant_rls_user]
      end

      def tenant_id=(val)
        Thread.current[:tenant_rls_tenant_id] = val
      end

      def tenant_id
        Thread.current[:tenant_rls_tenant_id]
      end

      def reset
        Thread.current[:tenant_rls_user] = nil
        Thread.current[:tenant_rls_tenant_id] = nil
      end
    end
  end
end
