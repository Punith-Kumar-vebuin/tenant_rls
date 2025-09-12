# TenantRls

A Ruby gem for implementing PostgreSQL Row-Level Security (RLS) in multi-tenant Rails applications with automatic thread-safe tenant context preservation.

## Features

- **Automatic Thread Context Preservation**: Thread.new automatically inherits tenant context without code changes
- **PostgreSQL RLS Integration**: Direct integration with PostgreSQL Row-Level Security policies
- **Multiple Resolution Strategies**: Support for Warden, custom authentication, background jobs, and manual tenant resolution
- **Thread-Safe Design**: Uses Concurrent::ThreadLocalVar for thread-safe tenant isolation
- **Background Job Support**: Automatic tenant context in Sidekiq and ActiveJob workers
- **Rails Integration**: Seamless integration with Rails controllers and models

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'tenant_rls'
```

And then execute:

```bash
bundle install
```

## Requirements

- Ruby 2.3.8 or higher
- Rails 4.2 or higher
- PostgreSQL 9.5 or higher (for RLS support)

## Quick Start

### 1. Enable ApplicationRecord Integration

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  
  # Enable RLS context management
  extend TenantRls::Context if defined?(TenantRls)
end
```

### 2. Configure the Gem

```ruby
# config/initializers/tenant_rls.rb
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid        # Resolution strategy
  config.tenant_id_column = :company_id           # Tenant ID column name
  config.debug_logging = Rails.env.development?   # Debug logging
  config.auto_thread_tenant_context = true        # Automatic thread context
end
```

### 3. Include in Controllers

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include TenantRls::Controller
end
```

## PostgreSQL Setup

### Enable RLS on Tables

```sql
-- Enable Row-Level Security
ALTER TABLE your_table ENABLE ROW LEVEL SECURITY;

-- Create tenant isolation policy
CREATE POLICY tenant_isolation_policy ON your_table
  USING (company_id = current_setting('tenant_rls.tenant_id')::bigint);
```

### Grant Application Permissions

```sql
-- Allow application user to bypass RLS for administrative operations
GRANT BYPASS_RLS ON your_table TO your_application_user;
```

## Tenant Resolution Strategies

### Hybrid Strategy (Recommended)

```ruby
config.tenant_resolver_strategy = :hybrid
```

Automatically detects context from web requests, background jobs, or manual settings. Provides the most flexible tenant resolution.

### Warden Strategy

```ruby
config.tenant_resolver_strategy = :warden
```

For applications using Devise/Warden authentication. Extracts tenant information from the current user.

### Custom Auth Strategy

```ruby
config.tenant_resolver_strategy = :custom_auth
```

For applications with custom authentication systems. Uses `current_company` and `current_user` methods.

### Job Context Strategy

```ruby
config.tenant_resolver_strategy = :job_context
```

Specifically for background job processing. Extracts tenant context from job arguments.

### Manual Strategy

```ruby
config.tenant_resolver_strategy = :manual
```

Requires explicit tenant setting via `TenantRls::Current.tenant_id = value`.

## Thread Context Preservation

The gem automatically preserves tenant context when creating new threads:

```ruby
# Tenant context is automatically preserved in threads
def background_processing
  TenantRls::Current.tenant_id = 12345
  
  Thread.new do
    # tenant_id is automatically available here
    SomeModel.create(name: "example") # Uses proper tenant isolation
    Rails.logger.info "Processing for tenant #{TenantRls::Current.tenant_id}"
  end
end
```

## Background Jobs Integration

### Sidekiq

```ruby
class ExampleWorker
  include Sidekiq::Worker
  include TenantRls::Job
  
  def perform(data)
    # Tenant context automatically available
    SomeModel.create(data)
  end
end
```

### ActiveJob

```ruby
class ExampleJob < ApplicationJob
  include TenantRls::Job
  
  def perform(data)
    # Tenant context automatically available
    SomeModel.create(data)
  end
end
```

## Manual Tenant Management

### Setting Tenant Context

```ruby
# Set tenant globally
TenantRls::Current.tenant_id = 12345
TenantRls::Current.user = current_user

# Block-scoped tenant context
TenantRls.with_tenant(tenant_id) do
  # Operations within this block use the specified tenant
  SomeModel.all # Automatically filtered by tenant
end
```

### Checking Current Context

```ruby
# Get current tenant information
tenant_id = TenantRls.current_tenant_id
tenant_id = TenantRls::Current.tenant_id
user = TenantRls::Current.user

# Reset tenant context
TenantRls.reset!
TenantRls::Current.reset
```

## Configuration Options

### Tenant Resolution Strategy

```ruby
# Available strategies: :hybrid, :warden, :custom_auth, :job_context, :manual
config.tenant_resolver_strategy = :hybrid
```

### Tenant ID Column

```ruby
# Specify the column name used for tenant identification
config.tenant_id_column = :account_id  # Default: :company_id
```

### Debug Logging

```ruby
# Enable detailed logging for troubleshooting
config.debug_logging = true
```

### Automatic Thread Context

```ruby
# Control automatic thread context preservation
config.auto_thread_tenant_context = true  # Default: true
```

## Advanced Usage

### Thread Context Management

```ruby
# Capture current context
context = TenantRls.capture_context

# Restore context in different thread
TenantRls.restore_context(context) do
  # Code runs with restored tenant context
end

# Create thread with explicit context management
TenantRls.thread_with_context do
  # Thread-safe tenant operations
end
```

### Custom Tenant Resolution

For applications with unique tenant resolution requirements:

```ruby
# Override resolver methods in initializer
module TenantRls
  class CustomAuthResolver < BaseResolver
    def self.resolve(context = {})
      # Custom tenant resolution logic
      context[:current_user]&.tenant_id
    end
  end
end
```

## Debugging

### Enable Debug Logging

```ruby
TenantRls.configure do |config|
  config.debug_logging = true
end
```

### Check Tenant Context

```ruby
# In Rails console or application code
puts "Current tenant: #{TenantRls::Current.tenant_id}"
puts "Current user: #{TenantRls::Current.user&.inspect}"

# Test thread context preservation
TenantRls::Current.tenant_id = 123
Thread.new { puts TenantRls::Current.tenant_id }.join # Should output: 123
```

### Verify RLS Configuration

```sql
-- Check current tenant setting in database
SHOW tenant_rls.tenant_id;

-- Verify RLS policies are active
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual 
FROM pg_policies 
WHERE schemaname = 'public';
```

## Performance Considerations

- Thread context preservation has minimal overhead
- No database connection pooling in threads - Rails handles connections per operation
- Tenant resolution occurs once per request/job
- Thread-local variables are automatically cleaned up

## Error Handling

The gem handles common error scenarios gracefully:

- Missing tenant context (operations continue without RLS)
- Invalid tenant IDs (logged and ignored)
- Database connection issues (proper cleanup)
- Thread creation failures (detailed error logging)

## Testing

### RSpec Configuration

```ruby
# spec/rails_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    TenantRls::Current.reset
  end
end
```

### Test Helper Methods

```ruby
# spec/support/tenant_helpers.rb
module TenantHelpers
  def with_tenant(tenant_id)
    original_tenant = TenantRls::Current.tenant_id
    TenantRls::Current.tenant_id = tenant_id
    yield
  ensure
    TenantRls::Current.tenant_id = original_tenant
  end
end

RSpec.configure do |config|
  config.include TenantHelpers
end
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/new-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`bundle exec rspec`)
5. Commit your changes (`git commit -am 'Add new feature'`)
6. Push to the branch (`git push origin feature/new-feature`)
7. Create a Pull Request

## License

The gem is available as open source under the [MIT License](https://opensource.org/licenses/MIT).

## Changelog

### Version 0.1.0

- Initial release with automatic thread context preservation
- PostgreSQL RLS integration
- Multiple tenant resolution strategies
- Background job support
- Thread-safe design with Concurrent::ThreadLocalVar
- Rails controller and model integration