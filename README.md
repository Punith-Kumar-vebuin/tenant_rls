# TenantRls

A Ruby gem for implementing PostgreSQL Row-Level Security (RLS) in multi-tenant Rails applications with simple, explicit tenant-aware threading.

## Features

- **TenantThread**: Simple Thread subclass that preserves tenant context explicitly
- **PostgreSQL RLS Integration**: Direct integration with PostgreSQL Row-Level Security policies
- **Multiple Resolution Strategies**: Support for Warden, custom authentication, background jobs, and manual tenant resolution
- **Thread-Safe Design**: Uses Concurrent::ThreadLocalVar for thread-safe tenant isolation
- **Background Job Support**: Automatic tenant context in Sidekiq and ActiveJob workers
- **Rails Integration**: Seamless integration with Rails controllers and models
- **AWS RDS Compatible**: Works with AWS RDS PostgreSQL instances

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

- Ruby 2.3.0 or higher (declared via `required_ruby_version` in the gemspec)
- Rails 4.0 or higher
- PostgreSQL 9.5 or higher (for RLS support)

> The gem still installs on Ruby 2.3.x for legacy services, but the
> security-patched versions of transitive dependencies (nokogiri, net-imap,
> rack-session, current Rails) require Ruby 3.1+. See
> [Security & Dependency Updates](#security--dependency-updates).

## Security & Dependency Updates

This gem declares **loose, uncapped** runtime dependencies (`rails >= 4.0`,
`activesupport >= 4.0`, `concurrent-ruby ~> 1.2`), so it does **not** pin you to
vulnerable versions. CVE patches for transitive gems (`nokogiri`, `net-imap`,
`rack-session`, Rails) are resolved by **each host application's own bundle**,
not by this gem.

To clear AWS Inspector findings in a consuming service:

```bash
bundle update nokogiri net-imap rack-session rails --conservative
bundle exec rspec   # then redeploy
```

For the full CVE triage (in-scope vs out-of-scope findings), the mixed-Ruby
upgrade path, and per-service instructions, see
[SECURITY_CVE_REVIEW.md](SECURITY_CVE_REVIEW.md).

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

## TenantThread - Tenant-Aware Threading

The gem provides `TenantThread` - a simple Thread subclass that explicitly preserves tenant context:

### Basic Usage

```ruby
# Simple tenant-aware thread
TenantRls::TenantThread.new do
  # tenant_id is automatically available here
  puts "Processing for tenant #{TenantRls::Current.tenant_id}"
  SomeModel.create(name: "example") # Uses proper tenant isolation
end
```

### With Database Connection Management

For long-running operations or AWS RDS environments, use `with_connection`:

```ruby
# Thread with dedicated database connection (recommended for server environments)
TenantRls::TenantThread.with_connection do
  # Guaranteed database connection with tenant context
  export_obj.update(status: 'ready')
  process_heavy_operation(export_obj)
end
```

### Real-World Example

```ruby
# In your service class
class ExportHistoryService
  def call
    # ... setup code ...

    # Background processing with tenant context
    TenantRls::TenantThread.with_connection do
      Rails.logger.info "Processing export for tenant #{TenantRls::Current.tenant_id}"
      export_obj.update(status: 'ready')
      process_export(export_obj)
      notify_completion(export_obj)
    end
  end
end
```

### Why TenantThread?

- **Explicit**: No monkey patching - you control when tenant context is preserved
- **Safe**: No interference with system threads, Puma, or other gems
- **AWS RDS Compatible**: Handles database session variables correctly
- **Simple**: Just replace `Thread.new` with `TenantRls::TenantThread.new`

## Migration from Thread.new

Replace your existing `Thread.new` calls:

```ruby
# Before: Regular Thread.new (loses tenant context)
Thread.new do
  SomeModel.create(name: "example")
end

# After: TenantThread (preserves tenant context)
TenantRls::TenantThread.new do
  SomeModel.create(name: "example")
end

# For database-heavy operations (recommended for servers)
TenantRls::TenantThread.with_connection do
  export_obj.update(status: 'ready')
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


## Advanced Usage

### Manual Context Management

```ruby
# Capture current context (for advanced use cases)
context = TenantRls.capture_context

# Restore context in different scope
TenantRls.restore_context(context) do
  # Code runs with restored tenant context
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
TenantRls::TenantThread.new { puts TenantRls::Current.tenant_id }.join # Should output: 123
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

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Current version: **0.2.2** (backward-compatible
bug fixes: restored hash-based worker args, dependency-free thread context
timestamp, and a fully green spec suite).

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