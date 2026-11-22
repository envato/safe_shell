module SafeShell
  class CommandFailedException < RuntimeError; end

  # Seconds a child gets to exit after a signal before the next step.
  GRACE_PERIOD = 1.0
  # Seconds between checks for the child having exited.
  POLL_INTERVAL = 0.01
  private_constant :GRACE_PERIOD, :POLL_INTERVAL

  def self.execute(command, *args)
    opts = args.last.kind_of?(Hash) ? args.pop : {}

    # Interrupts Ruby can defer (Thread#raise, which Timeout uses; Thread#kill;
    # the default signal handlers) are deferred except around the read and the
    # wait, so every descriptor and the pid are assigned when the ensure runs.
    # On CRuby an exception raised from a trap handler is not deferred.
    Thread.handle_interrupt(Object => :never) do
      read_end, write_end = IO.pipe
      new_stdout = new_stderr = nil
      pid = nil

      begin
        # Opened read-write: write-only blocks on a FIFO with no reader.
        new_stdout = opts[:stdout] ? File.open(opts[:stdout], "w+") : write_end
        new_stderr = opts[:stderr] ? File.open(opts[:stderr], "w+") : write_end
        env = opts[:env]
        # A command that reads stdin gets EOF at once rather than blocking.
        spawn_opts = {:in => File::NULL, :out => new_stdout, :err => new_stderr}

        # Passing the program as a two-element array forces Kernel#spawn to
        # exec it directly. A bare String with no further arguments would go
        # through /bin/sh -c whenever it contains shell metacharacters.
        program = [command.to_s, command.to_s]
        argv = args.map { |a| a.to_s }
        spawn_args = env ? [env, program] : [program]

        pid = spawn(*spawn_args, *argv, spawn_opts)

        Thread.handle_interrupt(Object => :immediate) do
          write_end.close
          output = read_end.read
          Process.waitpid(pid)
          pid = nil
          output
        end
      ensure
        begin
          # Close first: closing cannot block, and a child stuck writing to a
          # full pipe gets SIGPIPE (or EPIPE) and can exit. Neither a failing
          # close nor, on CRuby, a trap handler's exception may leave the rest
          # open.
          interruption = nil
          [read_end, write_end, new_stdout, new_stderr].each do |io|
            begin
              io.close if io && !io.closed?
            rescue SystemCallError, IOError
            rescue Exception => e
              interruption ||= e
            end
          end
          raise interruption if interruption
        ensure
          # So $? reflects this call, not the previous one.
          terminate_and_reap(pid) if pid
        end
      end
    end
  end

  def self.execute?(*args)
    execute(*args)
    $?.success?
  end

  def self.execute!(*args)
    execute(*args).tap do
      unless $?.success?
        # Leave the options hash out of the message: :env is where callers
        # put credentials for the child process.
        argv = args.last.kind_of?(Hash) ? args[0...-1] : args
        raise CommandFailedException.new("Shell command #{argv.inspect} failed with status #{$?}")
      end
    end
  end

  # Reaps pid, sending TERM and then KILL if it is still running. Each wait
  # is one GRACE_PERIOD, so the call returns within about two grace periods,
  # or three if an exception lands in it. A child that has not died by then
  # is left, and $? is nil or unchanged.
  def self.terminate_and_reap(pid)
    return if Process.waitpid(pid, Process::WNOHANG)
    Process.kill("TERM", pid)
    return if reap_by(pid, now + GRACE_PERIOD)
    Process.kill("KILL", pid)
    reap_by(pid, now + GRACE_PERIOD)
  rescue Errno::ESRCH, Errno::ECHILD
    # Something else in this process has already reaped it.
  rescue SystemCallError
    # The child cannot be signalled (it changed uid, say). It is left running
    # if it has not exited, and the caller's exception stands.
    begin
      Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
    end
  rescue Exception => interruption
    # On CRuby an exception raised from a trap handler is not deferred by
    # handle_interrupt, and a second one can land while the child is reaped.
    deadline = now + GRACE_PERIOD
    begin
      unless Process.waitpid(pid, Process::WNOHANG)
        Process.kill("KILL", pid)
        reap_by(pid, deadline)
      end
    rescue SystemCallError
    rescue Exception
      retry if now < deadline
    end
    raise interruption
  end
  private_class_method :terminate_and_reap

  # Waits until the deadline for pid to exit and reaps it. Returns pid once
  # reaped, or nil if it has not exited in time.
  def self.reap_by(pid, deadline)
    loop do
      reaped = Process.waitpid(pid, Process::WNOHANG)
      return reaped if reaped
      return nil if now > deadline
      sleep POLL_INTERVAL
    end
  end
  private_class_method :reap_by

  # A clock that cannot step backwards, for deadlines.
  def self.now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :now
end
