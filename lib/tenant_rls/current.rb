require 'concurrent'

module TenantRls
  class Current
    class << self
      def user=(val)
        user_var.value = val
      end

      def user
        user_var.value
      end

      def tenant_id=(val)
        tenant_id_var.value = val
      end

      def tenant_id
        tenant_id_var.value
      end

      def reset
        user_var.value = nil
        tenant_id_var.value = nil
      end

      private

      def user_var
        @user_var ||= Concurrent::ThreadLocalVar.new
      end

      def tenant_id_var
        @tenant_id_var ||= Concurrent::ThreadLocalVar.new
      end
    end
  end
end
