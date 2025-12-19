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

      expect(Datadog::Statsd::UDSRactorProxy)
        .to receive(:new)
        .exactly(0).times

      connection = Datadog::Statsd::UDSConnection.new('/tmp/socket')
      # We can't directly check the sender type, but we can verify it responds to the expected methods
      expect(connection).to respond_to(:close)
      expect(connection).to respond_to(:write)
    end

    it 'uses UDSRactorProxy when DOGSTATS_USE_RACTOR is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('DOGSTATS_USE_RACTOR').and_return('1')

      expect(Datadog::Statsd::UDSRactorProxy)
        .to receive(:new)
        .exactly(1).times

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

    # UDS server that listens and collects messages
    class TestServer
      def initialize(socket_file)
        @messages_received = []
        server_ready = false
        server_error = nil

        @server_thread = Thread.new do
          begin
            # Use Socket with SOCK_DGRAM for datagram communication (matching the client)
            server_socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM)
            server_socket.bind(Socket.pack_sockaddr_un(socket_file))
            server_ready = true

            loop do
              data, _ = server_socket.recvfrom(1024)
              break if data.empty?
              @messages_received << data
            end
            server_socket.close
          rescue => e
            server_error = e
          end
        end

        # Wait for server to be ready
        timeout = 1.0
        start_time = Time.now
        sleep 0.05 until server_ready || (Time.now - start_time) > timeout
        raise "Server failed to start: #{server_error}" if server_error
      end

      def stop(subject)
        # Closing the connection blocks on ractor termination. We know send will complete before
        # this returns.
        subject.close

        # Wait for server thread to finish. This should happen quickly since we closed the client.
        @server_thread.join(2)
        @server_thread.kill if @server_thread.alive?

        @messages_received
      end
    end

    describe 'actual message transmission' do
      require 'socket'
      require 'tempfile'

      let(:socket_file) do
        tempfile = Tempfile.new('test_socket')
        path = tempfile.path
        tempfile.close!
        path
      end

      let(:subject) do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('DOGSTATS_USE_RACTOR').and_return('1')

        Datadog::Statsd::UDSConnection.new(socket_file, logger: logger, telemetry: telemetry)
      end

      after do
        subject.close if subject
        sleep 0.1 # Let any pending operations finish
        File.unlink(socket_file) if File.exist?(socket_file)
      end

      it 'successfully sends and receives messages through the UDS socket' do
        test_server = TestServer.new(socket_file)

        # Send messages through the ractor connection
        test_message = 'counter.increment:1|c'
        subject.write(test_message)

        messages_received = test_server.stop(subject)

        # Verify the message was received
        expect(messages_received).to include(test_message)
      end

      it 'sends multiple messages correctly' do
        test_server = TestServer.new(socket_file)

        # Send multiple messages
        messages = ['metric1:1|c', 'metric2:2|g', 'metric3:100|ms']
        messages.each { |msg| subject.write(msg) }

        messages_received = test_server.stop(subject)

        # Verify all messages were received
        expect(messages_received.length).to be >= messages.length
        messages.each do |msg|
          expect(messages_received).to include(msg)
        end
      end
    end
  end
end
