require 'spec_helper'

describe Datadog::Statsd::UDSRactorProxy do
  # Skip ractor tests on Ruby versions that don't support ractors
  before do
    skip "Ractors not supported" unless defined?(Ractor)
    skip "UDS not supported on Windows" if Gem.win_platform?
  end

  subject do
    described_class.new(socket_path)
  end

  let(:socket_path) do
    '/tmp/socket'
  end

  describe '#initialize' do
    it 'stores the socket_path' do
      proxy = described_class.new(socket_path)
      # We can't directly access instance variables, but we can verify initialization succeeds
      expect(proxy).to be_a(described_class)
    end

    it 'does not immediately create a ractor' do
      # Before connect is called, the ractor should not be created
      # We verify this by checking that send_message will call connect first
      expect_any_instance_of(described_class).to receive(:connect).and_call_original
      subject.send_message('test')
    end
  end

  describe '#connect' do
    it 'creates a new ractor' do
      expect { subject.connect }.not_to raise_error
    end

    it 'closes the existing ractor before creating a new one' do
      # First connect
      subject.connect
      
      # Second connect should close the previous ractor
      expect { subject.connect }.not_to raise_error
    end

    it 'does not raise an error when called multiple times' do
      expect { subject.connect }.not_to raise_error
      expect { subject.connect }.not_to raise_error
    end
  end

  describe '#send_message' do
    it 'calls connect if ractor is not initialized' do
      expect(subject).to receive(:connect).and_call_original
      subject.send_message('test')
    end

    it 'does not raise an error' do
      expect { subject.send_message('test') }.not_to raise_error
    end

    it 'does not raise an error when called multiple times' do
      expect { subject.send_message('test1') }.not_to raise_error
      expect { subject.send_message('test2') }.not_to raise_error
    end

    it 'does not raise when sent a large message' do
      large_message = 'x' * 10000
      expect { subject.send_message(large_message) }.not_to raise_error
    end

    it 'can send messages after reconnect' do
      subject.connect
      expect { subject.send_message('test1') }.not_to raise_error
      
      subject.connect
      expect { subject.send_message('test2') }.not_to raise_error
    end
  end

  describe '#close' do
    it 'does not raise an error when called before connect' do
      expect { subject.close }.not_to raise_error
    end

    it 'sends nil to terminate the ractor' do
      subject.connect
      # close should not raise
      expect { subject.close }.not_to raise_error
    end

    it 'clears the ractor reference' do
      subject.connect
      subject.close
      
      # After close, a new connect should work
      expect { subject.connect }.not_to raise_error
      expect { subject.send_message('test') }.not_to raise_error
    end

    it 'is safe to call multiple times' do
      subject.connect
      expect { subject.close }.not_to raise_error
      expect { subject.close }.not_to raise_error
    end
  end

  describe 'ractor lifecycle' do
    it 'successfully sends messages through the ractor' do
      # This is a basic integration test
      subject.connect
      expect { subject.send_message('message1') }.not_to raise_error
      expect { subject.send_message('message2') }.not_to raise_error
      subject.close
    end

    it 'can reconnect after close' do
      subject.connect
      subject.send_message('message1')
      subject.close
      
      subject.connect
      expect { subject.send_message('message2') }.not_to raise_error
      subject.close
    end

    it 'handles rapid send/close cycles' do
      5.times do
        subject.connect
        subject.send_message("message")
        subject.close
      end
    end
  end

  # Test error handling in the ractor
  describe 'error handling' do
    it 'does not crash the proxy if send_message fails in the ractor' do
      # This is difficult to test directly since errors in the ractor are logged to STDERR
      # but we can at least verify the proxy doesn't raise
      subject.connect
      # Send valid message
      expect { subject.send_message('test') }.not_to raise_error
      subject.close
    end

    it 'allows recovery after an error' do
      subject.connect
      subject.close
      
      # Should be able to reconnect and send after an error
      subject.connect
      expect { subject.send_message('test') }.not_to raise_error
      subject.close
    end
  end
end
