require 'spec_helper'

RSpec.describe TenantRls::ThreadContextManager do
  let(:test_tenant_id) { 123 }
  let(:test_user) { double('User', id: 1) }

  before do
    # Set up a clean state
    TenantRls::Current.reset
    allow(TenantRls.configuration).to receive(:debug_logging).and_return(false)
    allow(ApplicationRecord).to receive(:with_tenant).and_yield
  end

  after do
    TenantRls::Current.reset
  end

  describe '.capture_current_context' do
    context 'when tenant context exists' do
      before do
        TenantRls::Current.tenant_id = test_tenant_id
        TenantRls::Current.user = test_user
      end

      it 'captures the current tenant context' do
        context = described_class.capture_current_context

        expect(context).to be_a(Hash)
        expect(context[:tenant_id]).to eq(test_tenant_id)
        expect(context[:user]).to eq(test_user)
        expect(context[:strategy]).to eq(TenantRls.configuration.tenant_resolver_strategy)
        expect(context[:captured_at]).to be_a(Time)
      end
    end

    context 'when no tenant context exists' do
      it 'captures nil values' do
        context = described_class.capture_current_context

        expect(context[:tenant_id]).to be_nil
        expect(context[:user]).to be_nil
      end
    end
  end

  describe '.restore_context_in_thread' do
    let(:context) do
      {
        tenant_id: test_tenant_id,
        user: test_user,
        strategy: :manual,
        captured_at: Time.current
      }
    end

    context 'with valid context' do
      it 'restores tenant context in current thread' do
        described_class.restore_context_in_thread(context) do
          expect(TenantRls::Current.tenant_id).to eq(test_tenant_id)
          expect(TenantRls::Current.user).to eq(test_user)
        end
      end

      it 'calls ApplicationRecord.with_tenant when block given' do
        expect(ApplicationRecord).to receive(:with_tenant).with(test_tenant_id).and_yield

        described_class.restore_context_in_thread(context) do
          # Block content
        end
      end
    end

    context 'with empty context' do
      it 'does nothing when tenant_id is blank' do
        empty_context = { tenant_id: nil, user: nil }

        described_class.restore_context_in_thread(empty_context) do
          expect(TenantRls::Current.tenant_id).to be_nil
        end
      end
    end

    context 'with invalid context' do
      it 'does nothing when context is not a hash' do
        expect do
          described_class.restore_context_in_thread("invalid") do
            # Should not execute
            raise "Should not reach here"
          end
        end.not_to raise_error
      end
    end
  end

  describe '.with_tenant_context' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
    end

    it 'creates a new thread with tenant context preserved' do
      context_in_thread = nil

      thread = described_class.with_tenant_context do
        context_in_thread = {
          tenant_id: TenantRls::Current.tenant_id,
          user: TenantRls::Current.user
        }
      end

      thread.join

      expect(context_in_thread[:tenant_id]).to eq(test_tenant_id)
      expect(context_in_thread[:user]).to eq(test_user)
    end

    it 'resets context after block execution' do
      thread = described_class.with_tenant_context do
        # Context should be preserved here
        expect(TenantRls::Current.tenant_id).to eq(test_tenant_id)
      end

      thread.join

      # Main thread context should be unchanged
      expect(TenantRls::Current.tenant_id).to eq(test_tenant_id)
    end
  end

  describe '.with_tenant_context_and_connection' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield
    end

    it 'creates a thread with both context and connection management' do
      expect(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield

      context_in_thread = nil

      thread = described_class.with_tenant_context_and_connection do
        context_in_thread = {
          tenant_id: TenantRls::Current.tenant_id,
          user: TenantRls::Current.user
        }
      end

      thread.join

      expect(context_in_thread[:tenant_id]).to eq(test_tenant_id)
      expect(context_in_thread[:user]).to eq(test_user)
    end
  end

  describe '.create_context_aware_thread' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
    end

    context 'with connection management enabled' do
      it 'creates thread with connection pooling' do
        allow(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield
        expect(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield

        thread = described_class.create_context_aware_thread(with_connection: true) do
          expect(TenantRls::Current.tenant_id).to eq(test_tenant_id)
        end

        thread.join
      end
    end

    context 'with connection management disabled' do
      it 'creates thread without connection pooling' do
        expect(ActiveRecord::Base.connection_pool).not_to receive(:with_connection)

        thread = described_class.create_context_aware_thread(with_connection: false) do
          expect(TenantRls::Current.tenant_id).to eq(test_tenant_id)
        end

        thread.join
      end
    end

    context 'with pre-captured context' do
      it 'uses provided context instead of capturing current' do
        custom_context = {
          tenant_id: 456,
          user: double('OtherUser'),
          strategy: :manual,
          captured_at: Time.current
        }

        thread = described_class.create_context_aware_thread(
          context: custom_context,
          with_connection: false
        ) do
          expect(TenantRls::Current.tenant_id).to eq(456)
        end

        thread.join
      end
    end
  end

  describe '.has_tenant_context?' do
    context 'when tenant context exists' do
      before { TenantRls::Current.tenant_id = test_tenant_id }

      it 'returns true' do
        expect(described_class.has_tenant_context?).to be true
      end
    end

    context 'when no tenant context exists' do
      it 'returns false' do
        expect(described_class.has_tenant_context?).to be false
      end
    end
  end

  describe '.current_context_info' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
    end

    it 'returns comprehensive context information' do
      info = described_class.current_context_info

      expect(info).to be_a(Hash)
      expect(info[:thread_id]).to eq(Thread.current.object_id)
      expect(info[:tenant_id]).to eq(test_tenant_id)
      expect(info[:user_present]).to be true
      expect(info[:strategy]).to eq(TenantRls.configuration.tenant_resolver_strategy)
    end
  end
end
