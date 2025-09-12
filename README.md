# TenantRls

A lightweight Ruby gem providing **automatic tenant context preservation** for multi-tenant Rails applications using PostgreSQL Row-Level Security (RLS).

## Key Features

- ✅ **Automatic `Thread.new` tenant context preservation** - No code changes needed!
- ✅ **PostgreSQL Row-Level Security (RLS) integration**
- ✅ **Thread-safe tenant isolation**
- ✅ **Multiple tenant resolution strategies**
- ✅ **Compatible with Ruby 2.3+ and Rails 4.2+**
- ✅ **Minimal performance overhead**

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'tenant_rls'
```

And then execute:

```bash
bundle install
```

## Quick Start

### 1. Configure Your ApplicationRecord

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  
  # Enable RLS context management
  extend TenantRls::Context if defined?(TenantRls)
end
```

### 2. Configure TenantRls

```ruby
# config/initializers/tenant_rls.rb
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid  # or :warden, :custom_auth, :job_context, :manual
  config.tenant_id_column = :company_id      # Your tenant ID column name
  config.debug_logging = false               # Enable for debugging
  config.auto_thread_tenant_context = true   # Automatic Thread.new context (recommended)
end
```

### 3. Include in Controllers

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include TenantRls::Controller
  
  # This automatically sets tenant context for all requests
end
```

## Automatic Thread Context Preservation

**The gem's killer feature**: Regular `Thread.new` calls automatically preserve tenant context!

### Before (Traditional Approach)
```ruby
# ❌ Problem: Lost tenant context in threads
def some_background_work
  Thread.new do
    # tenant_id is nil here - RLS doesn't work!
    SomeModel.create(name: "test")  # Creates record without tenant isolation
  end
end
```

### After (With TenantRls)
```ruby
# ✅ Solution: Automatic tenant context preservation
def some_background_work
  Thread.new do
    # tenant_id automatically preserved! 🎉
    SomeModel.create(name: "test")  # Creates record with proper tenant isolation
    Rails.logger.info "Works!"     # Full Rails environment available
    binding.pry if needed          # Debugging works perfectly
  end
end
```

### Real-World Example

```ruby
# app/services/export_history_service.rb
class ExportHistoryService
  def generate_report(export_obj)
    # Process immediately or in background
    if export_obj.priority == 'high'
      process_export(export_obj)
    else
      # Background processing - tenant context automatically preserved!
      Thread.new do
        export_obj.update(status: 'ready')
        process_export(export_obj)
        send_notification(export_obj)
      end
    end
  end
  
  private
  
  def process_export(export_obj)
    # This works in both main thread and background thread
    # tenant_id is automatically available via RLS
    records = SomeModel.where(active: true)  # Automatically filtered by tenant
    # ... export logic
  end
end
```

## Tenant Resolution Strategies

### 1. Hybrid Strategy (Recommended)
```ruby
config.tenant_resolver_strategy = :hybrid
```
Automatically detects context: web requests, background jobs, manual setting.

### 2. Warden Strategy
```ruby
config.tenant_resolver_strategy = :warden
```
For applications using Warden/Devise authentication.

### 3. Custom Auth Strategy
```ruby
config.tenant_resolver_strategy = :custom_auth
```
For custom authentication systems.

### 4. Manual Strategy
```ruby
config.tenant_resolver_strategy = :manual
```
For explicit tenant setting.

## Manual Tenant Context

```ruby
# Set tenant context manually
TenantRls::Current.tenant_id = 12345
TenantRls::Current.user = current_user

# Or use the block syntax
TenantRls.with_tenant(tenant_id) do
  # Your code here - tenant context is set
end
```

## PostgreSQL Row-Level Security Setup

### 1. Enable RLS on your tables

```sql
-- Enable RLS
ALTER TABLE your_table ENABLE ROW LEVEL SECURITY;

-- Create policy
CREATE POLICY tenant_isolation_policy ON your_table
  USING (company_id = current_setting('tenant_rls.tenant_id')::bigint);
```

### 2. Grant access to your application user

```sql
-- Allow your app to bypass RLS when needed (for admin operations)
GRANT BYPASS_RLS ON your_table TO your_app_user;
```

## Background Jobs Integration

Works automatically with popular background job libraries:

### Sidekiq
```ruby
class MyWorker
  include Sidekiq::Worker
  include TenantRls::Job  # Add this line
  
  def perform(data)
    # tenant_id automatically available
    SomeModel.create(data)  # Properly isolated by tenant
  end
end
```

### Active Job
```ruby
class MyJob < ApplicationJob
  include TenantRls::Job  # Add this line
  
  def perform(data)
    # tenant_id automatically available  
    SomeModel.create(data)  # Properly isolated by tenant
  end
end
```

## Advanced Configuration

### Disable Automatic Thread Context (if needed)
```ruby
TenantRls.configure do |config|
  config.auto_thread_tenant_context = false  # Disable automatic Thread.new patching
end
```

### Custom Tenant ID Column
```ruby
TenantRls.configure do |config|
  config.tenant_id_column = :account_id  # Use :account_id instead of :company_id
end
```

### Debug Logging
```ruby
TenantRls.configure do |config|
  config.debug_logging = true  # Enable detailed logging
end
```

## Troubleshooting

### Check Current Tenant Context
```ruby
# In rails console or your code
puts "Tenant ID: #{TenantRls::Current.tenant_id}"
puts "User: #{TenantRls::Current.user&.inspect}"
```

### Test Thread Context
```ruby
# Test in rails console
TenantRls::Current.tenant_id = 123

Thread.new do
  puts "Thread tenant_id: #{TenantRls::Current.tenant_id}"  # Should be 123
end.join
```

### Debug Logging
Enable debug logging to see tenant context flow:

```ruby
TenantRls.configure { |c| c.debug_logging = true }
```

Look for log messages like:
```
[TenantRls] Capturing thread context: tenant_id=12345
[TenantRls] Auto-restored tenant_id=12345 in Thread.new
```

## Performance

- **Minimal overhead**: Only captures context when `tenant_id` is present
- **No connection pooling**: Threads don't hold database connections
- **Efficient cleanup**: Automatic thread-local variable cleanup

## Ruby & Rails Compatibility

- **Ruby**: 2.3.8, 3.0+, 3.1.4+  
- **Rails**: 4.2+, 5.x, 6.x, 7.x, 8.x
- **PostgreSQL**: 9.5+ (RLS support required)

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Add tests for your changes
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request

## License

The gem is available as open source under the [MIT License](https://opensource.org/licenses/MIT).

## Changelog

### v2.0.0 - Automatic Thread Context
- ✅ **NEW**: Automatic `Thread.new` tenant context preservation
- ✅ **IMPROVED**: Eliminated connection pool exhaustion issues  
- ✅ **SIMPLIFIED**: Lightweight implementation with minimal overhead
- ✅ **BREAKING**: Removed `with_tenant_context_and_connection` (use `Thread.new` directly)

### v1.x.x - Legacy Versions
- Basic tenant context management
- Manual thread context methods