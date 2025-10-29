# frozen_string_literal: true

require 'concurrent'

module Datadog
  class Statsd
    # Sender is using a companion thread to flush and pack messages
    # in a `MessageBuffer`.
    # The communication with this thread is done using a `Queue`.
    # If the thread is dead, it is starting a new one to avoid having a blocked
    # Sender with no companion thread to communicate with (most of the time, having
    # a dead companion thread means that a fork just happened and that we are
    # running in the child process).
    class Sender
      def initialize(message_buffer, telemetry: nil, queue_size: UDP_DEFAULT_BUFFER_SIZE, logger: nil, flush_interval: nil, queue_class: Queue, thread_class: Thread)
        raise RuntimeError.new("Unsupported Queue Class: #{queue_class}") unless queue_class == Queue
        raise RuntimeError.new("Unsupported Thread Class: #{thread_class}") unless thread_class == Thread

        #Override
        queue_class = Concurrent::Array

        @message_buffer = message_buffer
        @telemetry = telemetry
        @queue_size = queue_size
        @logger = logger
        @mx = Mutex.new
        @queue_class = queue_class
        @thread_class = thread_class
        @done = false
        @flush_timer = if flush_interval
          Datadog::Statsd::Timer.new(flush_interval) { flush(sync: true) }
        else
          nil
        end
      end

      def flush(sync: false)
        @logger.warn { "Statsd: Flushing the queue synchronously and waiting" } if (@logger && @sync)
        # keep a copy around in case another thread is calling #stop while this method is running
        current_message_queue = @message_queue

        # don't try to flush if there is no message_queue instantiated or
        # no companion thread running
        if !current_message_queue
          @logger.debug { "Statsd: can't flush: no message queue ready" } if @logger
          return
        end
        if !@sender_thread.alive?
          @logger.debug { "Statsd: can't flush: no sender_thread alive" } if @logger
          return
        end

        current_message_queue.unshift(:flush)
        rendez_vous if sync
      end

      def rendez_vous
        # could happen if #start hasn't be called
        message_queue = @message_queue
        return unless message_queue

        # We use the queue as a waitable object.
        queue = Queue.new
        # tell sender-thread to notify us in the current
        # thread's queue
        message_queue.unshift(queue)
        # wait for the sender thread to send a message
        # once the flush is done
        queue.pop
      end

      def add(message)
        message_queue = @message_queue
        # if the thread does not exist, we assume we are running in a forked process,
        # empty the message queue and message buffers (these messages belong to
        # the parent process) and spawn a new companion thread.
        sender_thread = @sender_thread
        if sender_thread.nil? || !sender_thread.alive?
          @mx.synchronize {
            # an attempt was previously made to start the sender thread but failed.
            # skipping re-start
            return if @done
            # a call from another thread has already re-created
            # the companion thread before this one acquired the lock
            break if @sender_thread.alive?
            @logger.debug { "Statsd: companion thread is dead, re-creating one" } if @logger

            @message_buffer.reset
            start
            message_queue = @message_queue
            @flush_timer.start if @flush_timer && @flush_timer.stop?
          }
        end

        if message_queue.length <= @queue_size
          message_queue.unshift(message)
        else
          if @telemetry
            bytesize = message.respond_to?(:bytesize) ? message.bytesize : 0
            @telemetry.dropped_queue(packets: 1, bytes: bytesize)
          end
        end
      end

      def start
        @mx.synchronize {
          if @sender_thread.nil? || !@sender_thread.alive?
            begin
              # initialize a new message queue for the background thread
              @message_queue = @queue_class.new unless @message_queue
              # start background thread
              @sender_thread = @thread_class.new(&method(:send_loop))
              @sender_thread.name = "Statsd Sender" unless Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.3')
            rescue ThreadError => e
              @logger.debug { "Statsd: Failed to start sender thread: #{e.message}" } if @logger
              @done = true
            end
          end
        }

        @flush_timer.start if @flush_timer
      end

      # when calling stop, make sure that no other threads is trying
      # to close the sender nor trying to continue to `#add` more message
      # into the sender.
      def stop(join_worker: true)
        sender_thread = nil
        @mx.synchronize {
          @flush_timer.stop if @flush_timer

          message_queue = @message_queue
          message_queue.unshift(:close) if message_queue

          sender_thread = @sender_thread
          @sender_thread = nil
        }
        sender_thread.join if sender_thread && join_worker
      end

      private

      def send_loop
        loop do
          message = @message_queue.pop

          unless message
            sleep(1)
            break unless Thread.current == @sender_thread
            next
          end

          case message
          when :close
            break
          when :flush
            @message_buffer.flush
          when Queue
            # It doesn't matter what we push. This just causes rendez_vous to unblock.
            message.push(:go_on)
          else
            @message_buffer.add(message)
          end
        end
      end
    end
  end
end
