module TenantRls
  class Configuration
    attr_accessor :tenant_resolver_strategy, :tenant_id_column, :debug_logging

    def initialize
      @tenant_resolver_strategy = :warden
      @tenant_id_column = :company_id
      @debug_logging = false
    end

    def valid_strategies
      [:warden, :custom_auth, :job_context, :manual]
    end

    def tenant_resolver_strategy=(strategy)
      unless valid_strategies.include?(strategy)
        raise ArgumentError, "Invalid tenant resolver strategy: #{strategy}. Valid strategies are: #{valid_strategies.join(', ')}"
      end
      @tenant_resolver_strategy = strategy
    end

    # Derive the tenant object key name from the configured tenant id column.
    # For example, :company_id => :company, :account_id => :account
    def tenant_object_key
      column_name = tenant_id_column.to_s
      base = column_name.end_with?('_id') ? column_name.sub(/_id\z/, '') : column_name
      base.to_sym
    end
  end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
