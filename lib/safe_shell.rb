module SafeShell
  class CommandFailedException < RuntimeError; end

  def self.execute(command, *args)
    opts = args.last.kind_of?(Hash) ? args.pop : {}
    read_end, write_end = IO.pipe
    new_stdout = opts[:stdout] ? File.open(opts[:stdout], "w+") : write_end
    new_stderr = opts[:stderr] ? File.open(opts[:stderr], "w+") : write_end
    opts = {:in => read_end, :out => new_stdout, :err => new_stderr}
    pid = spawn(command, *(args.map { |a| a.to_s }), opts)
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
