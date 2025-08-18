# TenantRls

A flexible Rails gem for implementing PostgreSQL Row-Level Security (RLS) in multi-tenant applications. This gem provides multiple initialization patterns to support different authentication systems and deployment scenarios.

## Features

- **Multiple Authentication Patterns**: Support for Devise/Warden, custom authentication, and background job processing
- **PostgreSQL RLS Integration**: Automatic tenant context setting for database queries
- **Thread-Safe**: Uses Rails' CurrentAttributes for thread-safe tenant context
- **Flexible Configuration**: Easy configuration for different deployment scenarios
- **Background Job Support**: Special handling for background job processing with tenant context
- **Backward Compatible**: Maintains compatibility with existing Devise/Warden implementations

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'tenant_rls'
```

And then execute:

    $ bundle install

## Configuration

Configure the gem in an initializer (`config/initializers/tenant_rls.rb`):

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :custom_auth
  # Configure the tenant id column used across resolvers and contexts.
  # Defaults to :company_id. Examples: :account_id, :tenant_id
  config.tenant_id_column = :company_id
  config.debug_logging = Rails.env.development?
end
```

**Available Strategies:**
- `:warden` - For Devise/Warden authentication
- `:custom_auth` - For custom authentication systems
- `:job_context` - For background jobs and workers
- `:manual` - For testing and manual control
- `:hybrid` - **Recommended** for mixed environments (automatically detects context and switches between `:warden` and `:job_context`)

**Configuration Notes:**
- The configured `tenant_id_column` drives how tenant is resolved everywhere (controllers, jobs, and warden).
- If you set `tenant_id_column = :account_id`, the gem will look for:
  - Direct `account_id` values in hashes/payloads
  - A nested `account` object with an `id`
  - Methods like `current_account` on controllers (if available)
  - Associations or attributes on the user like `user.account_id` or `user.account.id`
- Backward compatible: existing `company_id`/`company` usage continues to work when `tenant_id_column` is left as `:company_id`.
- **For mixed environments**: Use `:hybrid` strategy to automatically handle both API sessions and background jobs without manual configuration.

## Usage Patterns

### Pattern 1: Custom Authentication (Backend API)

For applications using custom authentication with `current_user` and a configured tenant object (e.g., `current_company` or `current_account`):

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :custom_auth
end

class Api::V1::BaseController < ApplicationController
  def current_user
    @current_user ||= User.find_by(id: request.headers['x-user-id'])
  end

  # Example when tenant_id_column is :company_id
  def current_company
    @current_company ||= Company.find_by(id: request.headers['x-company-id'])
  end

  # If you configure tenant_id_column = :account_id, you can alternatively expose:
  # def current_account
  #   @current_account ||= Account.find_by(id: request.headers['x-account-id'])
  # end
end
```

### Pattern 2: Legacy Devise/Warden (Existing)

For existing applications using Devise with Warden:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :warden
end
```

### Pattern 3: Background Jobs & Workers (Enhanced)

The enhanced `job_context` strategy handles both Sidekiq workers and ActiveJob jobs automatically:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :job_context
end
```

#### Automatic Worker Integration

For Sidekiq workers, the gem automatically hooks into the `perform` method:

```ruby
class NotificationWorker
  include Sidekiq::Worker
  include TenantRls::Job

  def perform(notification_type, notification_data, tenant_id)
    Notifications::NotificationService.new(notification_type, notification_data, tenant_id).serve_notification
  end
end
```

**Worker Patterns Supported:**
- `def perform(notification_type, notification_data, <tenant_id_column>)`
- `def perform(notification_data, <tenant_id_column>)`
- `def perform(data_hash)` where `data_hash[<tenant_id_column>]` exists

#### Automatic Job Integration

For ActiveJob jobs, the gem automatically hooks into job execution:

```ruby
class SendNotificationJob
  include Sidekiq::Job
  include Common
  include TenantRls::Job

  def perform(service_key, payload)
    service_class = resolve(service_key)
    service_instance = service_class.new(from_job_data(payload))
    service_instance.send_notification
  end
end
```

**Job Data Patterns Supported:**
- Direct `<tenant_id_column>` in job data (e.g., `:company_id`, `:account_id`)
- Nested tenant object with `id` field using inferred key from `<tenant_id_column>` (e.g., `:company`, `:account`)
- JSON string payload with company information
- DeepHashie objects from `from_job_data` method

#### Manual Worker/Job Control

If you need manual control over tenant context:

```ruby
class CustomWorker
  include TenantRls::Job

  def perform(notification_type, notification_data, tenant_id)
    with_tenant_context_for_worker(notification_type, notification_data, tenant_id) do
      # Your worker logic here
    end
  end
end

class CustomJob
  include TenantRls::Job

  def perform(payload)
    with_tenant_context(from_job_data(payload)) do
      # Your job logic here
    end
  end
end
```

#### Configuration in Different Repositories

**Backend API Repository:**
```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :job_context
end
```

**Notification Service Repository:**
```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :job_context
  config.debug_logging = Rails.env.development?
end
```

### Pattern 4: Hybrid Strategy (Recommended for Mixed Environments)

For legacy repositories that need to handle both Warden (API sessions) and Sidekiq (background jobs/workers) within the same project, the hybrid strategy automatically detects execution context and switches between appropriate resolution strategies:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid
  config.tenant_id_column = :company_id
  config.debug_logging = Rails.env.development?
end
```

#### How Hybrid Strategy Works

The hybrid strategy intelligently detects the execution context and automatically chooses the appropriate tenant resolution approach:

**Sidekiq Context Detection:**
- Automatically detects when code is running within Sidekiq worker/job execution
- Uses `job_context` strategy logic for tenant resolution
- Supports all existing worker patterns (positional arguments, hash data, nested objects)

**API/Web Context Detection:**
- Automatically detects when code is running within web request/API call
- **Optimized Strategy Priority**: Warden first (fast web detection), then Sidekiq context
- **Performance Focused**: Minimal overhead with fast path detection and early returns
- Supports existing Warden-based authentication patterns

#### Context Detection Mechanisms

The hybrid resolver uses multiple detection methods for reliable context identification:

1. **Thread Context Variables**: Set during Sidekiq worker execution with version-specific support (Sidekiq 5.x, 6.x, 7.x+)
2. **Context Data Analysis**: Examines provided context for job-related vs. web-related data
3. **Call Stack Analysis**: Inspects the call stack for Sidekiq or Rails controller indicators
4. **Web Request Strategy Selection**: For web contexts, intelligently chooses between CustomAuth and Warden strategies
5. **Enhanced Fallback Strategy**: Multi-strategy fallback for maximum robustness

#### Enhanced Features

**Direct Tenant ID Extraction:**
- Scans `perform(*args)` arguments for tenant IDs in any position
- Prioritizes direct tenant ID values over complex resolution logic
- Supports configured `tenant_id_column` in hash arguments

**Sidekiq Version Compatibility:**
- Automatic detection and support for Sidekiq 5.x, 6.x, 7.x+
- Version-specific thread context management
- Graceful fallback for unknown versions

**Optimized Resolution Order:**

The hybrid strategy uses this optimized priority order for maximum performance:

1. **Warden Strategy**: Fast detection of web request with Warden context (highest priority)
2. **Sidekiq Strategy**: Direct tenant extraction from worker arguments or job data
3. **Minimal Fallback**: Fast fallback attempts for edge cases

**Performance Benefits:**
- **Fast Path Detection**: Early returns prevent unnecessary processing
- **Memoized Lookups**: Configuration values cached for repeated access
- **Minimal Logging**: Debug logs only when explicitly enabled
- **Efficient Scanning**: Optimized argument scanning with reverse iteration for common patterns

This ensures maximum performance while maintaining full backward compatibility.

#### Usage Examples

**Automatic Context Switching:**
```ruby
# In your controller (automatically uses Warden strategy)
class Api::V1::UsersController < ApplicationController
  def index
    # Tenant context automatically resolved via Warden
    @users = User.all
  end
end

# In your Sidekiq worker (automatically uses job_context strategy)
class NotificationWorker
  include Sidekiq::Worker
  include TenantRls::Job

  def perform(notification_type, notification_data, company_id)
    # Tenant context automatically resolved from worker arguments
    send_notification(notification_type, notification_data)
  end
end
```

**Debug Output:**
```
[TenantRls] HybridResolver detected execution context: web_request
[TenantRls] Controller tenant_id=123 using strategy=hybrid
[TenantRls] HybridResolver detected execution context: sidekiq
[TenantRls] Worker tenant_id=123 using strategy=hybrid
```

#### Migration from Separate Strategies

**Before (separate strategies):**
```ruby
# Different configurations for different services
# Service A (API)
TenantRls.configure { |config| config.tenant_resolver_strategy = :warden }

# Service B (Workers)
TenantRls.configure { |config| config.tenant_resolver_strategy = :job_context }
```

**After (unified hybrid strategy):**
```ruby
# Single configuration for mixed environment
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid
  config.tenant_id_column = :company_id
  config.debug_logging = Rails.env.development?
end
```

#### Troubleshooting Context Detection

Enable debug logging to see context detection in action:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid
  config.debug_logging = true
end
```

**Common Issues:**

1. **False Sidekiq Detection**: Check for conflicting thread variables or gems that modify thread context
2. **Missing Tenant Resolution**: Ensure your workers follow supported argument patterns or your controllers expose `current_user`/Warden
3. **Warden Context Not Set**:
   - Verify Warden is properly configured and `request.env['warden']` contains user
   - Check that user has tenant associations (e.g., `user.companies_users.first.company_id`)
   - Ensure controller context includes `request` object
4. **Custom Auth Context Missing**:
   - Verify `current_user` and `current_company` methods are available on controller
   - Check that tenant objects respond to `.id` method
5. **Configuration Issues**:
   - Ensure `tenant_id_column` matches your database schema
   - Verify tenant object associations follow naming conventions
6. **Sidekiq Version Issues**:
   - Check Sidekiq version compatibility (5.x, 6.x, 7.x+ supported)
   - Verify thread context variables are set correctly for your version
   - **Sidekiq 7+ Logging**: If you get `NoMethodError: undefined method 'any?' for true`, ensure you're using the latest version with fixed thread context management
7. **Performance Concerns**: Context detection adds minimal overhead; disable debug logging in production

**Debug Output Analysis:**
```ruby
# Enable debug logging to see resolver selection
TenantRls.configure { |c| c.debug_logging = true }

# Look for these log patterns:
[TenantRls] HybridResolver detected execution context: web_request
[TenantRls] HybridResolver: Using CustomAuthResolver for web request
[TenantRls] HybridResolver: Using WardenResolver for web request
[TenantRls] HybridResolver: Found potential tenant_id in args: 123
[TenantRls] Controller tenant_id=123 using strategy=hybrid
```

### Pattern 5: Manual/Testing

For testing or special cases where you need manual control:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :manual
end

TenantRls.with_tenant(tenant_id) do
  # Your code here with tenant context
end
```

## PostgreSQL Setup

Ensure your PostgreSQL database has the required RLS function:

```sql
CREATE SCHEMA IF NOT EXISTS tenant_rls;

CREATE OR REPLACE FUNCTION tenant_rls.check_current_tenant(col_value integer)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  AS $$
    SELECT
      NULLIF(current_setting('tenant_rls.tenant_id', TRUE), '') IS NOT NULL
      AND col_value = NULLIF(current_setting('tenant_rls.tenant_id', TRUE), '')::integer;
  $$;
```

Create policies on your tables:

```sql
ALTER TABLE your_table ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_policy ON your_table
  USING ( tenant_rls.check_current_tenant(company_id) )
  WITH CHECK ( tenant_rls.check_current_tenant(company_id) );
```

Note: Replace `company_id` in the example policy with your actual tenant column to match `tenant_id_column` if it differs.

## Testing

The gem includes comprehensive test support:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :manual
  config.debug_logging = true
end

RSpec.describe "Multi-tenant functionality" do
  it "isolates tenant data" do
    company1 = create(:company)
    company2 = create(:company)

    TenantRls.with_tenant(company1.id) do
      # Test company1 data access
    end

    TenantRls.with_tenant(company2.id) do
      # Test company2 data access
    end
  end
end
```

## Thread Safety

The gem uses Rails' `CurrentAttributes` for thread-safe tenant context storage:

```ruby
TenantRls.current_tenant_id
TenantRls::Current.tenant_id
TenantRls::Current.user
```

## Debugging

Enable debug logging to see tenant resolution in action:

```ruby
TenantRls.configure do |config|
  config.debug_logging = true
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/tenant_rls.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
