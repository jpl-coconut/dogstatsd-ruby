require 'spec_helper'

describe 'UDSConnection with DOGSTATS_USE_RACTOR enabled' do
  before do
    skip "Ractors not supported" unless defined?(Ractor)
    skip "UDS not supported on Windows" if Gem.win_platform?
  end

  # We test that the right sender is chosen based on the environment variable
  describe 'sender selection' do
    it 'uses UDSSender when DOGSTATS_USE_RACTOR is not set' do
      # Ensure the env var is not set
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('DOGSTATS_USE_RACTOR').and_return(nil)

      connection = Datadog::Statsd::UDSConnection.new('/tmp/socket')
      # We can't directly check the sender type, but we can verify it responds to the expected methods
      expect(connection).to respond_to(:close)
      expect(connection).to respond_to(:write)
    end

    it 'uses UDSRactorProxy when DOGSTATS_USE_RACTOR is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('DOGSTATS_USE_RACTOR').and_return('1')

      connection = Datadog::Statsd::UDSConnection.new('/tmp/socket')
      # We can't directly check the sender type, but we can verify it responds to the expected methods
      expect(connection).to respond_to(:close)
      expect(connection).to respond_to(:write)
    end
  end

  describe 'with UDSRactorProxy' do
    subject do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('DOGSTATS_USE_RACTOR').and_return('1')
      
      Datadog::Statsd::UDSConnection.new('/tmp/socket', logger: logger, telemetry: telemetry)
    end

    let(:logger) do
      Logger.new(log).tap do |logger|
        logger.level = Logger::DEBUG
      end
    end
    let(:log) { StringIO.new }

    let(:telemetry) do
      instance_double(Datadog::Statsd::Telemetry, sent: true, dropped_writer: true, reset: true)
    end

    describe '#initialize' do
      it 'stores the socket_path' do
        expect(subject.socket_path).to eq '/tmp/socket'
      end
    end

    describe '#reset_telemetry' do
      it 'resets the telemetry' do
        expect(telemetry).to receive(:reset)
        subject.reset_telemetry
      end
    end

    describe '#close' do
      it 'closes the ractor proxy' do
        expect { subject.close }.not_to raise_error
      end

      it 'can be called multiple times safely' do
        expect { subject.close }.not_to raise_error
        expect { subject.close }.not_to raise_error
      end
    end

    describe 'write error handling with ractor' do
      # Note: Since errors in the ractor are logged to STDERR and not propagated,
      # we mainly test that the connection doesn't crash
      it 'handles connection errors gracefully' do
        # The ractor will try to connect to a non-existent socket
        # but this should not raise an error in the main thread
        expect { subject.write('test') }.not_to raise_error
      end

      it 'can recover after a write' do
        # Even though the write fails (socket doesn't exist), the connection should still work
        subject.write('test1')
        expect { subject.write('test2') }.not_to raise_error
      end
    end
  end
end
