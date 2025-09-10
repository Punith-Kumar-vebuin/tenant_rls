# TenantRls

A flexible Rails gem for implementing PostgreSQL Row-Level Security (RLS) in multi-tenant applications. This gem provides multiple initialization patterns to support different authentication systems and deployment scenarios, with comprehensive thread-safe tenant context management.

## Features

- **Multiple Authentication Patterns**: Support for Devise/Warden, custom authentication, and background job processing
- **PostgreSQL RLS Integration**: Automatic tenant context setting for database queries
- **Thread-Safe Context Management**: Advanced thread-aware tenant context preservation across all thread operations
- **Background Thread Support**: Seamless tenant context preservation in `Thread.new`, background jobs, and async processing
- **Thread Extensions**: Drop-in replacements for `Thread.new` with automatic tenant context preservation
- **Flexible Configuration**: Easy configuration for different deployment scenarios
- **Background Job Support**: Special handling for background job processing with tenant context
- **Backward Compatible**: Maintains compatibility with existing Devise/Warden implementations
- **Comprehensive Testing Support**: Built-in utilities for testing multi-tenant applications

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

## Thread Context Management

### The Problem with Background Threads

When using `Thread.new` in a Rails multi-tenant application, the new thread doesn't inherit the tenant context from the parent thread. This causes Row-Level Security (RLS) to fail because `tenant_id` is not set:

```ruby
def process_data
  puts TenantRls.current_tenant_id  # => 123 (current tenant)

  # BROKEN: Thread loses tenant context
  Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      puts TenantRls.current_tenant_id  # => nil (lost!)
      # Database queries fail RLS checks here
      SomeModel.all  # Returns all records, ignoring tenant!
    end
  end
end
```

### Thread-Safe Solutions

The gem provides multiple thread-safe solutions that work with all tenant resolution strategies:

#### Method 1: Thread Extensions (Recommended)

Replace `Thread.new` with tenant-aware alternatives:

```ruby
def process_data
  puts TenantRls.current_tenant_id  # => 123

  # FIXED: Thread preserves tenant context
  Thread.with_tenant_context_and_connection do
    puts TenantRls.current_tenant_id  # => 123 (preserved!)
    # Database queries work correctly with RLS
    SomeModel.all  # Uses correct tenant_id
  end
end
```

**Available Thread Extensions:**

```ruby
# Basic tenant context preservation
Thread.with_tenant_context do
  # tenant_id preserved, manage DB connections yourself
end

# Tenant context + connection management (recommended)
Thread.with_tenant_context_and_connection do
  # Both tenant_id and DB connection are managed
end
```

#### Method 2: TenantRls Module Methods

```ruby
# Convenience methods for thread operations
TenantRls.thread_with_context do
  # Your work with preserved tenant context
end

TenantRls.thread_with_context_and_connection do
  # Work with preserved context and managed connections
end

# Manual context management
context = TenantRls.capture_context
Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    TenantRls.restore_context(context) do
      # Work with restored tenant context
    end
  end
end
```

#### Method 3: ThreadContextManager (Advanced)

```ruby
# Direct access to thread context manager
TenantRls::ThreadContextManager.with_tenant_context_and_connection do
  # Full control with explicit context management
end

# Flexible thread creation
TenantRls::ThreadContextManager.create_context_aware_thread(
  context: captured_context,
  with_connection: true
) do
  # Custom thread with specific context
end
```

### Thread Context Examples by Strategy

All thread context management features work seamlessly with every tenant resolution strategy:

#### Custom Auth Strategy + Threads

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :custom_auth
end

class Api::V1::ExportController < ApplicationController
  def create_export
    export = Export.create!(export_params)

    # Return immediate response
    render json: { id: export.id, status: 'processing' }

    # Process in background with preserved tenant context
    Thread.with_tenant_context_and_connection do
      begin
        export.update!(status: 'generating')
        data = generate_export_data(export.filters)
        export.update!(data: data, status: 'completed')
        ExportMailer.export_ready(export).deliver_now
      rescue => e
        export.update!(status: 'failed', error_message: e.message)
      end
    end
  end
end
```

#### Hybrid Strategy + Background Processing

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid
end

class NotificationService
  def send_notifications_async(user_ids)
    # Works in both web requests and Sidekiq workers
    Thread.with_tenant_context_and_connection do
      user_ids.each do |user_id|
        user = User.find(user_id)  # Uses correct tenant_id
        NotificationMailer.send_notification(user).deliver_now
      end
    end
  end
end
```

#### Manual Strategy + Testing

```ruby
RSpec.describe "Background processing" do
  it "maintains tenant context in background threads" do
    TenantRls::Current.tenant_id = 123

    result_tenant_id = nil
    Thread.with_tenant_context do
      result_tenant_id = TenantRls.current_tenant_id
    end.join

    expect(result_tenant_id).to eq(123)
  end
end
```

### Real-World Thread Context Examples

#### 1. File Processing Service

```ruby
class FileProcessor
  def process_upload_async(file_path)
    Thread.with_tenant_context_and_connection do
      file_data = File.read(file_path)
      processed_records = parse_and_validate(file_data)

      # Save to database with proper tenant isolation
      processed_records.each do |record|
        ProcessedDocument.create!(record)
      end

      File.delete(file_path)
    end
  end
end
```

#### 2. Batch Processing with Multiple Threads

```ruby
class BatchProcessor
  def process_large_dataset_concurrently(dataset)
    chunks = dataset.in_groups_of(100)

    threads = chunks.map do |chunk|
      Thread.with_tenant_context_and_connection do
        chunk.compact.each do |item|
          ProcessedItem.create!(
            original_id: item.id,
            processed_at: Time.current,
            tenant_id: TenantRls.current_tenant_id
          )
        end
      end
    end

    threads.each(&:join)
  end
end
```

#### 3. Email Sending Service

```ruby
class EmailService
  def send_bulk_emails_async(email_data)
    Thread.with_tenant_context_and_connection do
      email_data.each do |data|
        user = User.find(data[:user_id])  # Correct tenant scope
        EmailMailer.send_email(user, data[:content]).deliver_now

        # Log in tenant's audit trail
        AuditLog.create!(
          action: 'email_sent',
          user_id: data[:user_id],
          details: data[:content]
        )
      end
    end
  end
end
```

### Debugging Thread Context

```ruby
# Check context in different scenarios
class DebugService
  def self.check_thread_context
    puts "Main thread: #{TenantRls.current_tenant_id}"

    # Regular thread (loses context)
    Thread.new do
      puts "Regular thread: #{TenantRls.current_tenant_id}"  # => nil
    end.join

    # Context-aware thread (preserves context)
    Thread.with_tenant_context do
      puts "Context thread: #{TenantRls.current_tenant_id}"  # => 123
      puts "Has context?: #{TenantRls::ThreadContextManager.has_tenant_context?}"
      puts "Context info: #{TenantRls::ThreadContextManager.current_context_info}"
    end.join
  end
end
```

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

**With Thread Context Management:**

```ruby
class Api::V1::DataController < Api::V1::BaseController
  def export_data
    render json: { status: 'started' }

    # Background processing with preserved tenant context
    Thread.with_tenant_context_and_connection do
      data = DataModel.all  # Uses correct tenant_id from current_company
      generate_export_file(data)
    end
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

**With Thread Context Management:**

```ruby
class ApplicationController < ActionController::Base
  def background_user_task
    # Preserve Warden user context in background thread
    Thread.with_tenant_context_and_connection do
      current_user.process_data  # current_user available via preserved context
      UserActivityLog.create!(user: current_user, action: 'data_processed')
    end
  end
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
    # Main job work with automatic tenant context
    send_notifications(notification_type, notification_data)

    # Spawn additional background work with preserved context
    Thread.with_tenant_context_and_connection do
      # Additional processing that needs database access
      cleanup_expired_notifications
      log_notification_metrics
    end
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

    # Main job work
    service_instance.send_notification

    # Background cleanup with preserved tenant context
    Thread.with_tenant_context_and_connection do
      cleanup_job_data(payload)
      update_job_statistics
    end
  end
end
```

**Job Data Patterns Supported:**
- Direct `<tenant_id_column>` in job data (e.g., `:company_id`, `:account_id`)
- Nested tenant object with `id` field using inferred key from `<tenant_id_column>` (e.g., `:company`, `:account`)
- JSON string payload with company information
- DeepHashie objects from `from_job_data` method

### Pattern 4: Hybrid Strategy (Recommended for Mixed Environments)

For legacy repositories that need to handle both Warden (API sessions) and Sidekiq (background jobs/workers) within the same project, the hybrid strategy automatically detects execution context and switches between appropriate resolution strategies:

```ruby
TenantRls.configure do |config|
  config.tenant_resolver_strategy = :hybrid
  config.tenant_id_column = :company_id
  config.debug_logging = Rails.env.development?
end
```

**With Thread Context Management:**

```ruby
# Works automatically in both web requests and background jobs
class UniversalService
  def process_data_async(data)
    # Hybrid strategy automatically resolves tenant context
    # Thread context management works in both scenarios
    Thread.with_tenant_context_and_connection do
      # This works whether called from:
      # 1. Web request (uses Warden/CustomAuth strategy)
      # 2. Sidekiq worker (uses JobContext strategy)

      ProcessedData.create!(data.merge(
        tenant_id: TenantRls.current_tenant_id,
        processed_at: Time.current
      ))
    end
  end
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

**With Thread Context Management:**

```ruby
RSpec.describe "Multi-tenant functionality" do
  it "maintains tenant context in background threads" do
    TenantRls::Current.tenant_id = 123

    # Test thread context preservation
    Thread.with_tenant_context do
      expect(TenantRls.current_tenant_id).to eq(123)
 
      # Test database operations
      user = User.create!(name: "Test User")
      expect(User.all).to include(user)
    end.join
  end
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

## Thread Safety & Context Management

The gem uses Rails' `CurrentAttributes` with `Concurrent::ThreadLocalVar` for thread-safe tenant context storage:

```ruby
TenantRls.current_tenant_id
TenantRls::Current.tenant_id
TenantRls::Current.user
```

### Thread Context Utilities

```ruby
# Check if current thread has tenant context
TenantRls::ThreadContextManager.has_tenant_context?

# Get detailed context information
TenantRls::ThreadContextManager.current_context_info

# Capture context for later use
context = TenantRls::ThreadContextManager.capture_current_context

# Restore context in a different thread
TenantRls::ThreadContextManager.restore_context_in_thread(context) do
  # Work with restored context
end
```

### Migration from Thread.new

**Before (loses tenant context):**
```ruby
Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    # tenant context lost here!
    Model.create!(data)
  end
end
```

**After (preserves tenant context):**
```ruby
Thread.with_tenant_context_and_connection do
  # tenant context preserved!
  Model.create!(data)
end
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

  it "preserves tenant context across threads" do
    TenantRls::Current.tenant_id = 123

    results = []
    threads = (1..3).map do
      Thread.with_tenant_context do
        results << TenantRls.current_tenant_id
      end
    end

    threads.each(&:join)
    expect(results).to all(eq(123))
  end
end
```

## Debugging

Enable debug logging to see tenant resolution and thread context management in action:

```ruby
TenantRls.configure do |config|
  config.debug_logging = true
end
```

**Debug Output Examples:**
```
[TenantRls] Controller tenant_id=123 using strategy=custom_auth
[TenantRls] ▶ SET tenant_rls.tenant_id=123 for Controller
[TenantRls::ThreadContext] Restoring tenant_id=123 in thread 47011731234440
[TenantRls::ThreadContext] ▶ SET tenant_rls.tenant_id=123 in thread
[TenantRls] ◀ RESET tenant_rls.tenant_id=123 for Controller
```

### Common Thread Context Issues

1. **Thread loses tenant context**: Use `Thread.with_tenant_context_and_connection` instead of `Thread.new`
2. **Database connection issues in threads**: Ensure you use the `_and_connection` variants for database operations
3. **Context not preserved in nested threads**: Each thread needs its own context preservation
4. **Performance concerns**: Context capture is ~0.1ms overhead, minimal impact

### Troubleshooting Thread Issues

```ruby
# Debug thread context state
def debug_thread_context
  puts "Main thread tenant_id: #{TenantRls.current_tenant_id}"
  puts "Has context: #{TenantRls::ThreadContextManager.has_tenant_context?}"

  Thread.with_tenant_context do
    puts "Thread tenant_id: #{TenantRls.current_tenant_id}"
    puts "Thread context info: #{TenantRls::ThreadContextManager.current_context_info}"
  end.join
end
```

## Performance

### Thread Context Performance

- **Context capture**: ~0.1ms overhead
- **Thread creation**: Same as regular Thread.new
- **Memory usage**: Minimal additional memory per thread
- **Database connections**: Properly managed through Rails connection pooling

### Best Practices

1. **Use `with_tenant_context_and_connection` for database operations**
2. **Use `with_tenant_context` when you manage connections yourself**
3. **Capture context early** if you need to pass it between systems
4. **Always test** background operations to ensure tenant isolation
5. **Log tenant_id** in background jobs for debugging
6. **Disable debug logging** in production for optimal performance

## API Reference

### TenantRls Module Methods

```ruby
# Core tenant management
TenantRls.with_tenant(tenant_id, &block)
TenantRls.current_tenant_id
TenantRls.reset!

# Thread context management
TenantRls.thread_with_context(&block)
TenantRls.thread_with_context_and_connection(&block)
TenantRls.capture_context
TenantRls.restore_context(context, &block)
```

### Thread Extensions

```ruby
# Enhanced Thread class methods
Thread.with_tenant_context(&block)
Thread.with_tenant_context_and_connection(&block)

# Instance methods
thread.mark_tenant_context_preserved!
thread.has_tenant_context?
thread.tenant_context_info
```

### ThreadContextManager

```ruby
# Context management
TenantRls::ThreadContextManager.capture_current_context
TenantRls::ThreadContextManager.restore_context_in_thread(context, &block)

# Thread creation
TenantRls::ThreadContextManager.with_tenant_context(&block)
TenantRls::ThreadContextManager.with_tenant_context_and_connection(&block)
TenantRls::ThreadContextManager.create_context_aware_thread(options, &block)

# Utilities
TenantRls::ThreadContextManager.has_tenant_context?
TenantRls::ThreadContextManager.current_context_info
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/tenant_rls.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).