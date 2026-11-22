module SafeShell
  class CommandFailedException < RuntimeError; end

  def self.execute(command, *args)
    opts = args.last.kind_of?(Hash) ? args.pop : {}
    read_end, write_end = IO.pipe
    new_stdout = opts[:stdout] ? File.open(opts[:stdout], "w+") : write_end
    new_stderr = opts[:stderr] ? File.open(opts[:stderr], "w+") : write_end
    env = opts[:env]
    opts = {:in => read_end, :out => new_stdout, :err => new_stderr}

    # Passing the program as a two-element array forces Kernel#spawn to exec
    # it directly. A bare String with no further arguments would go through
    # /bin/sh -c whenever it contains shell metacharacters.
    program = [command.to_s, command.to_s]
    argv = args.map { |a| a.to_s }

    pid = if env
      spawn(env, program, *argv, opts)
    else
      spawn(program, *argv, opts)
    end

    write_end.close
    output = read_end.read
    Process.waitpid(pid)
    read_end.close
    output
  end

  def self.execute?(*args)
    execute(*args)
    $?.success?
  end

  def self.execute!(*args)
    execute(*args).tap do
      raise_command_failed_exception(*args) unless $?.success?
    end
  end

private

  def self.raise_command_failed_exception(*args)
    raise CommandFailedException.new("Shell command #{args.inspect} failed with status #{$?}")
  end

end
