# Shared loop runner for commands that poll on a schedule.
module Carson
	class Runtime
		module LoopRunner
			LOOP_STOP_SIGNALS = %w[INT TERM].freeze
			LOOP_SLEEP_SLICE_SECONDS = 0.25

		private

			def run_signal_aware_loop!( loop_name:, loop_seconds:, cycle_line:, sleep_line: nil )
				cycle_count = 0
				stop_requested = false
				previous_handlers = install_loop_stop_handlers! do
					stop_requested = true
				end

				loop do
					break if stop_requested

					cycle_count += 1
					puts_line ""
					puts_line cycle_line.call( cycle_count )
					yield cycle_count
					break if stop_requested

					puts_line sleep_line.call( loop_seconds ) if sleep_line
					loop_runner_wait( seconds: loop_seconds ) { stop_requested }
				end

				puts_line "#{loop_name} loop stopped after #{cycle_count} cycle#{plural_suffix( count: cycle_count )}"
				EXIT_OK
			rescue Interrupt
				puts_line "#{loop_name} loop stopped after #{cycle_count} cycle#{plural_suffix( count: cycle_count )}"
				EXIT_OK
			rescue SignalException => exception
				raise unless graceful_loop_signal?( exception )

				puts_line "#{loop_name} loop stopped after #{cycle_count} cycle#{plural_suffix( count: cycle_count )}"
				EXIT_OK
			ensure
				restore_loop_stop_handlers!( previous_handlers ) if previous_handlers
			end

			def install_loop_stop_handlers!
				LOOP_STOP_SIGNALS.each_with_object( {} ) do |signal_name, handlers|
					handlers[ signal_name ] = loop_runner_trap( signal_name ) { yield signal_name }
				end
			end

			def restore_loop_stop_handlers!( previous_handlers )
				previous_handlers.each do |signal_name, previous_handler|
					loop_runner_trap( signal_name, previous_handler )
				end
			end

			def graceful_loop_signal?( exception )
				signo = exception.respond_to?( :signo ) ? exception.signo : nil
				LOOP_STOP_SIGNALS.any? do |signal_name|
					Signal.list.fetch( signal_name, nil ) == signo
				end
			end

			def loop_runner_wait( seconds: )
				deadline = loop_runner_monotonic_now + seconds.to_f
				while ( remaining = deadline - loop_runner_monotonic_now ) > 0
					break if block_given? && yield
					loop_runner_sleep( [ remaining, LOOP_SLEEP_SLICE_SECONDS ].min )
				end
			end

			def loop_runner_trap( signal_name, handler = nil, &block )
				if handler
					Signal.trap( signal_name, handler )
				else
					Signal.trap( signal_name, &block )
				end
			end

			def loop_runner_monotonic_now
				Process.clock_gettime( Process::CLOCK_MONOTONIC )
			end

			def loop_runner_sleep( seconds )
				sleep seconds
			end
		end

		include LoopRunner
	end
end
