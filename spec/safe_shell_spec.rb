# frozen_string_literal: true

require "spec_helper"
require "safe_shell"
require "pathname"
require "timeout"
require "tmpdir"
require "fileutils"

RSpec.describe SafeShell do
  let(:dir) { @dir = Dir.mktmpdir }
  let(:output_file) { File.join(dir, "output.txt") }
  let(:error_file) { File.join(dir, "error.txt") }

  after { FileUtils.remove_entry(@dir) if @dir }

  def open_descriptors
    skip "needs /dev/fd" unless File.directory?("/dev/fd")
    Dir.entries("/dev/fd").size
  end

  # Ruby warns when the default internal encoding is set, so the warning is
  # silenced for the assignment and the restore.
  def with_default_internal(encoding)
    was = Encoding.default_internal
    set_default_internal(encoding)
    yield
  ensure
    set_default_internal(was)
  end

  def set_default_internal(encoding)
    verbose, $VERBOSE = $VERBOSE, nil
    Encoding.default_internal = encoding
  ensure
    $VERBOSE = verbose
  end

  it "returns the output of the command" do
    expect(SafeShell.execute("echo", "Hello, world!")).to eql("Hello, world!\n")
  end

  it "passes shell metacharacters in arguments to the command literally" do
    [
      "$HOME", "`date`", "$(date)", "'quoted'", '"quoted"', "a|b", "a>b", "a<b", "a&&b", "a&", "a;b", "*", "~", "a\nb", "",
      "-n", "a b", "a\tb", "a\\b", "%s", "#a", "!a", "{a,b}", "café"
    ].each do |arg|
      expect(SafeShell.execute("printf", "%s", arg)).to eql(arg), "for #{arg.inspect}"
    end
  end

  it "passes generated strings of shell metacharacters to the command literally" do
    # No "-": printf may read an argument of dashes as an option of its own.
    alphabet = [*" \t\n$`'\"\\|&;<>()[]{}*?~#!%=".chars, "a", "é"]
    50.times do
      arg = Array.new(rand(1..20)) { alphabet.sample }.join
      expect(SafeShell.execute("printf", "%s", arg)).to eql(arg), "for #{arg.inspect}"
    end
  end

  it "returns output larger than a pipe holds" do
    output = Timeout.timeout(5) { SafeShell.execute("head", "-c", "300000", "/dev/zero") }
    expect(output.bytesize).to eql(300_000)
    expect($?.exitstatus).to eql(0)
  end

  it "returns the bytes the command wrote, untranscoded, when a default internal encoding is set" do
    # "café" in UTF-8, then two bytes no UTF-8 String may hold.
    bytes = [99, 97, 102, 195, 169, 255, 254]
    internal = Encoding.default_external == Encoding::UTF_8 ? Encoding::ISO_8859_1 : Encoding::UTF_8
    with_default_internal(internal) do
      output = SafeShell.execute("printf", 'caf\303\251\377\376')
      expect(output.bytes).to eql(bytes)
      expect(output.encoding).to eql(Encoding.default_external)
    end
  end

  it "never passes a command with no arguments to a shell" do
    expect {
      SafeShell.execute("echo ;echo INJECTED")
    }.to raise_error(Errno::ENOENT)
  end

  it "never passes a command with only options to a shell" do
    expect {
      SafeShell.execute("echo $HOME", env: { "HOME" => "/nowhere" })
    }.to raise_error(Errno::ENOENT)
  end

  it "adds the given environment variables to the parent's" do
    result = SafeShell.execute("env")
    expect(result).to_not include("HELLO=world")
    expect(result).to_not include("GOOD=day")

    result = SafeShell.execute("env", env: { "HELLO" => "world", "GOOD" => "day" })
    expect(result).to include("HELLO=world")
    expect(result).to include("GOOD=day")
    expect(result).to include("PATH=#{ENV["PATH"]}")
  end

  it "unsets an environment variable given as nil" do
    ENV["SAFE_SHELL_SPEC_UNSET"] = "set"
    expect(SafeShell.execute("env")).to include("SAFE_SHELL_SPEC_UNSET=set")
    expect(SafeShell.execute("env", env: { "SAFE_SHELL_SPEC_UNSET" => nil })).not_to include("SAFE_SHELL_SPEC_UNSET")
  ensure
    ENV.delete("SAFE_SHELL_SPEC_UNSET")
  end

  it "gives the command an empty stdin rather than blocking" do
    output = Timeout.timeout(5) { SafeShell.execute("cat") }
    expect(output).to eql("")
    expect($?.exitstatus).to eql(0)
  end

  it "sets $? to the exit status of the command" do
    SafeShell.execute("test", "a", "=", "a")
    expect($?.exitstatus).to eql(0)

    SafeShell.execute("test", "a", "=", "b")
    expect($?.exitstatus).to eql(1)
  end

  it "accepts a Pathname as an argument" do
    expect(SafeShell.execute("printf", "%s", Pathname.new("/tmp"))).to eql("/tmp")
  end

  context "resource handling" do
    it "closes the redirect files it opens" do
      before = open_descriptors
      5.times { SafeShell.execute("echo", "x", stdout: output_file, stderr: error_file) }
      expect(open_descriptors).to eql(before)
    end

    it "closes the pipe when the command cannot be started" do
      before = open_descriptors
      5.times do
        expect { SafeShell.execute("safe-shell-no-such-command") }.to raise_error(Errno::ENOENT)
      end
      expect(open_descriptors).to eql(before)
    end

    it "closes the pipe when a redirect file cannot be opened" do
      before = open_descriptors
      5.times do
        expect {
          SafeShell.execute("echo", "x", stdout: output_file, stderr: File.join(dir, "no-such-dir", "error.txt"))
        }.to raise_error(Errno::ENOENT)
      end
      expect(open_descriptors).to eql(before)
    end
  end

  context "interruption" do
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A file a command creates once it is ready to be interrupted.
    def ready_file
      @ready_file ||= File.join(dir, "ready")
    end

    # The trap comes before the file: ready_file must mean TERM is already
    # ignored.
    def ignoring_term
      ["sh", "-c", 'trap "" TERM; : > "$1"; exec sleep 30', "sh", ready_file]
    end

    NEVER_READY = "the command did not create its ready_file"

    # Records the pid SafeShell spawns. With await_ready, spawn does not return
    # until ready_file exists, and then sleeps for then_sleep seconds. SafeShell
    # defers a timeout until spawn returns, so the timeout lands only once the
    # command is ready.
    def spawned_pid(await_ready: false, then_sleep: 0)
      allow(SafeShell).to(receive(:spawn).and_wrap_original do |spawn, *args|
        @spawned = spawn.call(*args)
        if await_ready
          @awaited = true
          deadline = now + 10
          sleep 0.01 until File.exist?(ready_file) || (@never_ready = now > deadline)
          sleep then_sleep
        end
        @spawn_returned_at = now
        @spawned
      end)
      lambda { @spawned }
    end

    # Seconds since spawn returned the command to SafeShell.
    def since_spawn
      raise NEVER_READY if @never_ready

      now - @spawn_returned_at
    end

    def cruby_only
      skip "only CRuby delivers a trap handler's exception during the cleanup" unless RUBY_ENGINE == "ruby"
    end

    # Runs the block with a USR1 handler that raises, numbering each exception.
    def with_raising_trap
      raised = 0
      previous = trap("USR1") { raise "raised from trap handler #{raised += 1}" }
      yield
    ensure
      trap("USR1", previous)
    end

    after do
      if @spawned
        begin
          unless Process.waitpid(@spawned, Process::WNOHANG)
            Process.kill("KILL", @spawned)
            Process.waitpid(@spawned)
          end
        rescue Errno::ECHILD, Errno::ESRCH
        end
      end
      raise NEVER_READY if @never_ready
      raise "ready_file needs spawned_pid(await_ready: true)" if @ready_file && !@awaited
    end

    it "terminates and reaps the child if the read is interrupted" do
      pid = spawned_pid
      before = open_descriptors
      expect {
        Timeout.timeout(0.5) { SafeShell.execute("sleep", "30", stdout: output_file) }
      }.to raise_error(Timeout::Error)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["TERM"])
      expect(open_descriptors).to eql(before)
    end

    it "terminates and reaps the child if interrupted while spawning" do
      pid = nil
      allow(SafeShell).to receive(:spawn).and_wrap_original do |spawn, *args|
        @spawned = pid = spawn.call(*args)
        sleep 0.3
        pid
      end
      expect {
        Timeout.timeout(0.1) { SafeShell.execute("sleep", "30") }
      }.to raise_error(Timeout::Error)
      expect($?.pid).to eql(pid)
      expect($?.termsig).to eql(Signal.list["TERM"])
    end

    it "lets a child blocked writing to a full pipe exit when interrupted" do
      # The sleep gives yes time to fill the pipe. If it has not, the pipe is
      # closed before yes writes again, and the expectations hold all the same.
      pid = spawned_pid(await_ready: true, then_sleep: 0.3)
      expect {
        Timeout.timeout(0.1) { SafeShell.execute("sh", "-c", 'trap "" TERM; : > "$1"; exec yes', "sh", ready_file) }
      }.to raise_error(Timeout::Error)
      expect(since_spawn).to be < 1
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["PIPE"]).or be_nil
    end

    it "kills the child if it ignores TERM" do
      pid = spawned_pid(await_ready: true)
      expect {
        Timeout.timeout(0.5) { SafeShell.execute(*ignoring_term) }
      }.to raise_error(Timeout::Error)
      expect(since_spawn).to be < 3
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "gives the child the whole grace period even when its thread is woken early" do
      pid = spawned_pid(await_ready: true)
      waiter = Thread.current
      sibling = Thread.new do
        loop do
          waiter.wakeup
          sleep 0.001
        end
      end
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", "trap 'kill $!; sleep 0.2; exit 0' TERM; sleep 30 & : > \"$1\"; wait", "sh", ready_file) }
        }.to raise_error(Timeout::Error)
      ensure
        sibling.kill
        sibling.join
      end
      expect($?.pid).to eql(pid.call)
      expect($?).to be_success
    end

    it "finishes the cleanup if interrupted again while waiting for the child" do
      pid = spawned_pid(await_ready: true)
      expect {
        Timeout.timeout(0.8) do
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        end
      }.to raise_error(Timeout::Error)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "reaps the child if a trap handler raises while waiting for it" do
      pid = spawned_pid(await_ready: true)
      allow(Process).to receive(:kill).and_call_original
      interruptions = 1
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if (interruptions -= 1) >= 0
      end
      with_raising_trap do
        expect {
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        }.to raise_error(RuntimeError, "raised from trap handler 1")
      ensure
        interruptions = 0
      end
      expect(since_spawn).to be < (RUBY_ENGINE == "ruby" ? 1 : 3)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "reaps the child if a trap handler raises again while killing it" do
      cruby_only
      pid = spawned_pid(await_ready: true)
      allow(Process).to receive(:kill).and_call_original
      interruptions = 2
      allow(Process).to receive(:kill).with(/TERM|KILL/, anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if (interruptions -= 1) >= 0
      end
      with_raising_trap do
        expect {
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        }.to raise_error(RuntimeError, "raised from trap handler 1")
      ensure
        interruptions = 0
      end
      expect(since_spawn).to be < 1
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "stops retrying the kill at the deadline if a trap handler keeps raising" do
      cruby_only
      pid = spawned_pid(await_ready: true)
      allow(Process).to receive(:kill).and_call_original
      armed = true
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        armed ? raise("raised from a later trap handler") : kill.call(*args)
      end
      with_raising_trap do
        expect {
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        }.to raise_error(RuntimeError, "raised from trap handler 1")
      ensure
        armed = false
      end
      expect(since_spawn).to be_between(1, 2.5)
      expect { Process.kill(0, pid.call) }.not_to raise_error
    end

    it "keeps the trap handler's exception if the kill after it is refused" do
      cruby_only
      pid = spawned_pid(await_ready: true)
      allow(Process).to receive(:kill).and_call_original
      armed = true
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        armed ? raise(Errno::EPERM) : kill.call(*args)
      end
      with_raising_trap do
        expect {
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        }.to raise_error(RuntimeError, "raised from trap handler 1")
      ensure
        armed = false
      end
      expect(since_spawn).to be < 1
      expect { Process.kill(0, pid.call) }.not_to raise_error
    end

    it "closes every descriptor if a trap handler raises while closing one" do
      cruby_only
      pid = spawned_pid
      armed = true
      allow_any_instance_of(File).to receive(:close).and_wrap_original do |close, *args|
        close.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      before = open_descriptors
      with_raising_trap do
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sleep", "30", stdout: output_file, stderr: error_file) }
        }.to raise_error(RuntimeError, "raised from trap handler 1")
      ensure
        armed = false
      end
      expect(open_descriptors).to eql(before)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["TERM"])
    end

    it "leaves a child that does not die after KILL" do
      pid = spawned_pid(await_ready: true)
      ignore_kill = true
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        ignore_kill ? 1 : kill.call(*args)
      end
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute(*ignoring_term) }
        }.to raise_error(Timeout::Error)
        expect(since_spawn).to be < 4
        expect($?).to satisfy("be nil or describe another command") { |status| status.nil? || status.pid != pid.call }
        expect { Process.kill(0, pid.call) }.not_to raise_error
      ensure
        ignore_kill = false
      end
    end

    it "leaves a child it is not permitted to signal and keeps the caller's exception" do
      pid = spawned_pid
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with("TERM", anything).and_raise(Errno::EPERM)
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sleep", "30") }
        }.to raise_error(Timeout::Error)
        expect(since_spawn).to be < 1
        expect($?).to satisfy("be nil or describe another command") { |status| status.nil? || status.pid != pid.call }
        expect { Process.kill(0, pid.call) }.not_to raise_error
      ensure
        Process.kill("KILL", pid.call)
        Process.waitpid(pid.call)
      end
    end

    it "reaps a child that has already exited" do
      read_end, write_end = IO.pipe
      pid = spawn("true", out: write_end)
      write_end.close
      read_end.read
      read_end.close
      SafeShell.send(:terminate_and_reap, pid)
      expect($?.pid).to eql(pid)
      expect($?).to be_success
    end

    it "does nothing for a child another waiter has reaped" do
      pid = spawn("true")
      Process.waitpid(pid)
      status = $?
      expect(Process).not_to receive(:kill)
      expect { SafeShell.send(:terminate_and_reap, pid) }.not_to raise_error
      expect($?).to satisfy("be nil or unchanged") { |after| after.nil? || after.equal?(status) }
    end
  end

  it "returns stderr along with stdout" do
    output = SafeShell.execute("sh", "-c", "echo out; echo err >&2")
    expect(output).to include("out\n")
    expect(output).to include("err\n")
  end

  context "output redirection" do
    it "returns only stderr when stdout is redirected" do
      output = SafeShell.execute("sh", "-c", "echo out; echo err >&2", stdout: output_file)
      expect(output).to eql("err\n")
      expect(File.read(output_file)).to eql("out\n")
    end

    it "returns nothing when both streams are redirected" do
      output = SafeShell.execute("sh", "-c", "echo out; echo err >&2", stdout: output_file, stderr: error_file)
      expect(output).to eql("")
      expect(File.read(output_file)).to eql("out\n")
      expect(File.read(error_file)).to eql("err\n")
    end

    it "lets you redirect both streams to the same file" do
      SafeShell.execute("sh", "-c", "echo out; echo err >&2; echo out2", stdout: output_file, stderr: output_file)
      expect(File.read(output_file)).to eql("out\nerr\nout2\n")
    end

    it "treats two spellings of one path as the same file" do
      SafeShell.execute("sh", "-c", "echo out; echo err >&2; echo out2", stdout: output_file, stderr: File.join(dir, "..", File.basename(dir), "output.txt"))
      expect(File.read(output_file)).to eql("out\nerr\nout2\n")
    end

    it "lets you redirect stdout to a file" do
      output = SafeShell.execute("echo", "Hello, world!", stdout: output_file)
      expect(output).to eql("")
      expect(File.read(output_file)).to eql("Hello, world!\n")
    end

    it "lets you redirect stderr to a file" do
      output = SafeShell.execute("sh", "-c", "echo err >&2", stderr: output_file)
      expect(output).to eql("")
      expect(File.read(output_file)).to eql("err\n")
    end

    it "accepts a Pathname for each redirect file" do
      output = SafeShell.execute("sh", "-c", "echo out; echo err >&2", stdout: Pathname.new(output_file), stderr: Pathname.new(error_file))
      expect(output).to eql("")
      expect(File.read(output_file)).to eql("out\n")
      expect(File.read(error_file)).to eql("err\n")
    end

    it "truncates the file stdout is redirected to" do
      File.write(output_file, "left by an earlier call\n")
      SafeShell.execute("echo", "out", stdout: output_file)
      expect(File.read(output_file)).to eql("out\n")
    end

    it "truncates the file stderr is redirected to" do
      File.write(error_file, "left by an earlier call\n")
      SafeShell.execute("sh", "-c", "echo err >&2", stderr: error_file)
      expect(File.read(error_file)).to eql("err\n")
    end
  end

  context "options" do
    let(:untouched) { File.join(dir, "untouched.txt") }

    it "accepts a Hash of options passed with **" do
      options = { env: { "SAFE_SHELL_SPEC" => "set" } }
      expect(SafeShell.execute("sh", "-c", "printf %s \"$SAFE_SHELL_SPEC\"", **options)).to eql("set")
    end

    it "raises ArgumentError for an option it does not know, running nothing" do
      expect(SafeShell).not_to receive(:spawn)
      expect { SafeShell.execute("pwd", chdir: "/") }.to raise_error(ArgumentError, /chdir/)
      expect { SafeShell.execute("pwd", "stdout" => untouched) }.to raise_error(ArgumentError)
      expect { SafeShell.execute?("pwd", chdir: "/") }.to raise_error(ArgumentError, /chdir/)
      expect { SafeShell.execute!("pwd", chdir: "/") }.to raise_error(ArgumentError, /chdir/)
    end

    it "passes the options through execute?" do
      script = 'test "$SAFE_SHELL_SPEC" = set'
      expect(SafeShell.execute?("sh", "-c", script, env: { "SAFE_SHELL_SPEC" => "set" })).to eql(true)
      expect(SafeShell.execute?("sh", "-c", script, env: { "SAFE_SHELL_SPEC" => "other" })).to eql(false)
    end

    it "passes the options through execute!" do
      options = { env: { "SAFE_SHELL_SPEC" => "set" } }
      expect(SafeShell.execute!("sh", "-c", "printf %s \"$SAFE_SHELL_SPEC\"", **options)).to eql("set")
    end

    [
      ["a symbol-keyed Hash", lambda { |path| { stdout: path, env: { "PATH" => "/nonexistent" } } }],
      ["a string-keyed Hash", lambda { |path| { "stdout" => path } }],
      ["a Hash subclass", lambda { |path| Class.new(Hash).new.merge!(stdout: path) }]
    ].each do |description, build|
      it "raises ArgumentError for #{description} as the last argument, running nothing" do
        hash = build.call(untouched)
        expect(SafeShell).not_to receive(:spawn)
        expect { SafeShell.execute("echo", "x", hash) }.to raise_error(ArgumentError, /cannot be a Hash/)
        expect { SafeShell.execute?("echo", "x", hash) }.to raise_error(ArgumentError)
        expect { SafeShell.execute!("echo", "x", hash) }.to raise_error(ArgumentError)
        expect { SafeShell.execute("echo", *["x", hash]) }.to raise_error(ArgumentError)
        expect(File.exist?(untouched)).to eql(false)
      end
    end

    it "raises ArgumentError for a Hash among the arguments" do
      expect { SafeShell.execute("echo", { stdout: untouched }, "x") }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for a Hash as the command, running nothing" do
      hash = { env: { "SECRET" => "hunter2" } }
      expect(SafeShell).not_to receive(:spawn)
      [:execute, :execute?, :execute!].each do |method|
        expect { SafeShell.public_send(method, hash) }.to raise_error(ArgumentError, /cannot be a Hash/) { |error|
          expect(error.message).not_to include("hunter2")
        }
      end
    end

    it "keeps the Hash out of the ArgumentError message" do
      expect { SafeShell.execute("echo", { env: { "SECRET" => "hunter2" } }) }.to raise_error(ArgumentError) { |error|
        expect(error.message).not_to include("hunter2")
      }
    end
  end

  context ".execute?" do
    it "returns true if the command succeeds" do
      expect(SafeShell.execute?("true")).to eql(true)
    end

    it "returns false if the command fails" do
      expect(SafeShell.execute?("false")).to eql(false)
    end

    it "returns nil if a signal terminates the command" do
      expect(SafeShell.execute?("sh", "-c", "kill -TERM $$")).to be_nil
    end

    it "raises Errno::ENOENT rather than returning false if the program cannot be found" do
      expect {
        SafeShell.execute?("safe-shell-no-such-command")
      }.to raise_error(Errno::ENOENT)
    end
  end

  context ".execute!" do
    it "returns the output of the command" do
      expect(SafeShell.execute!("echo", "Hello, world!")).to eql("Hello, world!\n")
    end

    it "raises Errno::ENOENT rather than CommandFailedException if the program cannot be found" do
      expect {
        SafeShell.execute!("safe-shell-no-such-command")
      }.to raise_error(Errno::ENOENT)
    end

    it "raises an exception if the command fails" do
      expect {
        SafeShell.execute!("test", "a", "=", "b")
      }.to raise_error(SafeShell::CommandFailedException, /\["test", "a", "=", "b"\] failed with status/)
    end

    it "puts the command, arguments, status and output on the exception" do
      expect {
        SafeShell.execute!("sh", "-c", "echo out; echo err >&2; exit 3", Pathname.new("x"))
      }.to raise_error(SafeShell::CommandFailedException) { |error|
        expect(error.command).to eql("sh")
        expect(error.args).to eql(["-c", "echo out; echo err >&2; exit 3", "x"])
        expect(error.status.exitstatus).to eql(3)
        expect(error.output).to eql("out\nerr\n")
      }
    end

    it "reports a command terminated by a signal through the exception's status" do
      expect {
        SafeShell.execute!("sh", "-c", "kill -TERM $$")
      }.to raise_error(SafeShell::CommandFailedException) { |error|
        expect(error.status.signaled?).to eql(true)
        expect(error.status.termsig).to eql(Signal.list["TERM"])
        expect(error.status.exitstatus).to be_nil
      }
    end

    it "keeps environment variables out of the exception message" do
      expect {
        SafeShell.execute!("false", env: { "SECRET" => "hunter2" })
      }.to raise_error(SafeShell::CommandFailedException) { |error|
        expect(error.message).to include('["false"]')
        expect(error.message).not_to include("hunter2")
        expect(error.message).not_to include("SECRET")
      }
    end
  end
end

RSpec.describe SafeShell::CommandFailedException do
  it "can be constructed and raised with a message alone, or with nothing" do
    expect { raise SafeShell::CommandFailedException }.to raise_error(SafeShell::CommandFailedException, "SafeShell::CommandFailedException")
    expect { raise SafeShell::CommandFailedException, "boom" }.to raise_error(SafeShell::CommandFailedException, "boom")
    error = SafeShell::CommandFailedException.new("boom")
    expect(error.message).to eql("boom")
    expect(error.command).to be_nil
    expect(error.args).to eql([])
    expect(error.status).to be_nil
    expect(error.output).to be_nil
  end
end
