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
