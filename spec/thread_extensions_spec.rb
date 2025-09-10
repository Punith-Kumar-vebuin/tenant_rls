require 'spec_helper'

RSpec.describe 'Thread Extensions' do
  let(:test_tenant_id) { 123 }
  let(:test_user) { double('User', id: 1) }

  before do
    TenantRls::Current.reset
    allow(TenantRls.configuration).to receive(:debug_logging).and_return(false)
    allow(ApplicationRecord).to receive(:with_tenant).and_yield
  end

  after do
    TenantRls::Current.reset
  end

  describe 'Thread.with_tenant_context' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
    end

    it 'delegates to TenantRls::ThreadContextManager' do
      expect(TenantRls::ThreadContextManager).to receive(:with_tenant_context).and_call_original

      Thread.with_tenant_context do
        # Test block
      end.join
    end

    it 'preserves tenant context in the new thread' do
      context_in_thread = nil

      thread = Thread.with_tenant_context do
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

  describe 'Thread.with_tenant_context_and_connection' do
    before do
      TenantRls::Current.tenant_id = test_tenant_id
      TenantRls::Current.user = test_user
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield
    end

    it 'delegates to TenantRls::ThreadContextManager' do
      expect(TenantRls::ThreadContextManager).to receive(:with_tenant_context_and_connection).and_call_original

      Thread.with_tenant_context_and_connection do
        # Test block
      end.join
    end

    it 'manages both context and connections' do
      expect(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield

      context_in_thread = nil

      thread = Thread.with_tenant_context_and_connection do
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

  describe 'Thread instance methods' do
    let(:thread) { Thread.new { sleep 0.01 } }

    after { thread.kill if thread.alive? }

    describe '#mark_tenant_context_preserved!' do
      it 'marks the thread as having preserved context' do
        thread.mark_tenant_context_preserved!
        expect(thread[:tenant_rls_context_preserved]).to be true
      end
    end

    describe '#has_tenant_context?' do
      it 'delegates to ThreadContextManager' do
        expect(TenantRls::ThreadContextManager).to receive(:has_tenant_context?)
        thread.has_tenant_context?
      end
    end

    describe '#tenant_context_info' do
      it 'delegates to ThreadContextManager' do
        expect(TenantRls::ThreadContextManager).to receive(:current_context_info)
        thread.tenant_context_info
      end
    end
  end
end
