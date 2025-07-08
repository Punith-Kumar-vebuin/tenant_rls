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
  config.tenant_id_column = :company_id
  config.debug_logging = Rails.env.development?
end
```

## Usage Patterns

### Pattern 1: Custom Authentication (Backend API)

For applications using custom authentication with `current_user` and `current_company`:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :custom_auth
end

class Api::V1::BaseController < ApplicationController
  def current_user
    @current_user ||= User.find_by(id: request.headers['x-user-id'])
  end

  def current_company
    @current_company ||= Company.find_by(id: request.headers['x-company-id'])
  end
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

  def perform(notification_type, notification_data, company_id)
    Notifications::NotificationService.new(notification_type, notification_data, company_id).serve_notification
  end
end
```

**Worker Patterns Supported:**
- `def perform(notification_type, notification_data, company_id)`
- `def perform(notification_data, company_id)`
- `def perform(data_hash)` where `data_hash[:company_id]` exists

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
- Direct `company_id` in job data
- Nested `company` object with `id` field
- JSON string payload with company information
- DeepHashie objects from `from_job_data` method

#### Manual Worker/Job Control

If you need manual control over tenant context:

```ruby
class CustomWorker
  include TenantRls::Job

  def perform(notification_type, notification_data, company_id)
    with_tenant_context_for_worker(notification_type, notification_data, company_id) do
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

### Pattern 4: Manual/Testing

For testing or special cases where you need manual control:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :manual
end

TenantRls.with_tenant(company_id) do
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
