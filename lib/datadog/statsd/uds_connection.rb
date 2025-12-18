# frozen_string_literal: true

require_relative 'connection'

module Datadog
  class Statsd
    class UDSSender 
      def initialize(socket_path)
        @socket_path = socket_path
        @socket = nil
      end

      def close
        @socket.close if @socket
        @socket = nil
      end

      attr_reader :socket

      def connect
        close if @socket

        @socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM)
        @socket.connect(Socket.pack_sockaddr_un(@socket_path))
      end

      # send_message is writing the message in the socket, it may create the socket if nil
      # It is not thread-safe but since it is called by either the Sender bg thread or the
      # SingleThreadSender (which is using a mutex while Flushing), only one thread must call
      # it at a time.
      def send_message(message)
        connect unless @socket
        @socket.sendmsg_nonblock(message)
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ENOENT => e
        # TODO: FIXME: This error should be considered as a retryable error in the
        # Connection class. An even better solution would be to make BadSocketError inherit
        # from a specific retryable error class in the Connection class.
        raise BadSocketError, "#{e.class}: #{e}"
      end
    end

    class UDSRactorProxy
      def initialize(socket_path)
        @socket_path = socket_path
      end

      def connect
        close if @ractor_sender
        @ractor_sender = Ractor.new(@socket_path) { |socket_path|
          sender = UDSSender.new(socket_path)
          loop do
            message = Ractor.receive
            unless message
              sender.close
              break
            end

            begin
              sender.send_message(message)
            rescue Exception => e
              # The send is intentionally asynchronous so there is no way to deliver this
              # reliably to the caller. Just log
              STDERR.puts(e)
            end
          end
        }
      end

      def send_message(message)
        connect unless @ractor_sender
        @ractor_sender.send(message)
      end

      def close
        return unless @ractor_sender
        @ractor_sender.send(nil)
        @ractor_sender = nil
      end
    end

    class UDSConnection < Connection
      class BadSocketError < StandardError; end

      # DogStatsd unix socket path
      attr_reader :socket_path

      def initialize(socket_path, **kwargs)
        super(**kwargs)
        @socket_path = socket_path

        unless ENV["DOGSTATS_USE_RACTOR"]
          @socket_sender = UDSSender.new(socket_path)
        else
          @socket_sender = UDSRactorProxy.new(socket_path)
        end
      end

      def close
        @socket_sender.close()
      end

      unless ENV["DOGSTATS_USE_RACTOR"]
        # This is for the rspec tests only.
        def socket
          @socket_sender.socket
        end
      end

      private

      def send_message(message)
        @socket_sender.send_message(message)
      end

      def connect
        @socket_sender.connect()
      end
    end
  end
end
