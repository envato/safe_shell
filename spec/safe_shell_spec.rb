require 'spec_helper'
require 'safe_shell'
require 'pathname'
require 'timeout'
require 'tmpdir'
require 'fileutils'

RSpec.describe SafeShell do
  it "returns the output of the command" do
    expect(SafeShell.execute("echo", "Hello, world!")).to eql("Hello, world!\n")
  end

  it "passes shell metacharacters in arguments to the command literally" do
    ["$HOME", "`date`", "$(date)", "'quoted'", '"quoted"', "a|b", "a>b", "a&&b", "a;b", "*", "~", "a\nb", "", "-n"].each do |arg|
      expect(SafeShell.execute("printf", "%s", arg)).to eql(arg), "for #{arg.inspect}"
    end
  end

  it "never passes a command with no arguments to a shell" do
    expect {
      SafeShell.execute("echo ;echo INJECTED")
    }.to raise_error(Errno::ENOENT)
  end

  it "never passes a command with only options to a shell" do
    expect {
      SafeShell.execute("echo $HOME", :env => { "HOME" => "/nowhere" })
    }.to raise_error(Errno::ENOENT)
  end

  it "adds the given environment variables to the parent's" do
    result = SafeShell.execute("env")
    expect(result).to_not include("HELLO=world")
    expect(result).to_not include("GOOD=day")

    result = SafeShell.execute("env", :env => { "HELLO" => "world", "GOOD" => "day" })
    expect(result).to include("HELLO=world")
    expect(result).to include("GOOD=day")
    expect(result).to include("PATH=#{ENV["PATH"]}")
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
    def open_descriptors
      skip "needs /dev/fd" unless File.directory?("/dev/fd")
      Dir.entries("/dev/fd").size
    end

    it "closes the redirect files it opens" do
      before = open_descriptors
      5.times { SafeShell.execute("echo", "x", :stdout => "tmp/output.txt", :stderr => "tmp/error.txt") }
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
          SafeShell.execute("echo", "x", :stdout => "tmp/output.txt", :stderr => "tmp/no-such-dir/error.txt")
        }.to raise_error(Errno::ENOENT)
      end
      expect(open_descriptors).to eql(before)
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def spawned_pid
      allow(SafeShell).to receive(:spawn).and_wrap_original { |spawn, *args| @spawned = spawn.call(*args) }
      lambda { @spawned }
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
    end

    it "terminates and reaps the child if the read is interrupted" do
      pid = spawned_pid
      before = open_descriptors
      expect {
        Timeout.timeout(0.5) { SafeShell.execute("sleep", "30", :stdout => "tmp/output.txt") }
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

    it "kills the child if it ignores TERM" do
      pid = spawned_pid
      started = now
      expect {
        Timeout.timeout(0.5) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
      }.to raise_error(Timeout::Error)
      expect(now - started).to be < 3
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "gives the child the whole grace period even when its thread is woken early" do
      pid = spawned_pid
      waiter = Thread.current
      sibling = Thread.new { loop { waiter.wakeup; sleep 0.001 } }
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", %q(trap 'kill $!; sleep 0.2; exit 0' TERM; sleep 30 & wait)) }
        }.to raise_error(Timeout::Error)
      ensure
        sibling.kill
        sibling.join
      end
      expect($?.pid).to eql(pid.call)
      expect($?).to be_success
    end

    it "finishes the cleanup if interrupted again while waiting for the child" do
      pid = spawned_pid
      expect {
        Timeout.timeout(0.8) do
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        end
      }.to raise_error(Timeout::Error)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "reaps the child if a trap handler raises while waiting for it" do
      pid = spawned_pid
      previous = trap("USR1") { raise "raised from trap handler" }
      allow(Process).to receive(:kill).and_call_original
      interruptions = 1
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if (interruptions -= 1) >= 0
      end
      started = now
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        }.to raise_error(RuntimeError, "raised from trap handler")
      ensure
        interruptions = 0
        trap("USR1", previous)
      end
      expect(now - started).to be < (RUBY_ENGINE == "ruby" ? 1 : 3)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "reaps the child if a trap handler raises again while killing it" do
      skip "only CRuby delivers a trap handler's exception during the cleanup" unless RUBY_ENGINE == "ruby"
      pid = spawned_pid
      previous = trap("USR1") { raise "raised from trap handler" }
      allow(Process).to receive(:kill).and_call_original
      interruptions = 2
      allow(Process).to receive(:kill).with(/TERM|KILL/, anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if (interruptions -= 1) >= 0
      end
      started = now
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        }.to raise_error(RuntimeError, "raised from trap handler")
      ensure
        interruptions = 0
        trap("USR1", previous)
      end
      expect(now - started).to be < (RUBY_ENGINE == "ruby" ? 1 : 3)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["KILL"])
    end

    it "stops retrying the kill at the deadline if a trap handler keeps raising" do
      skip "only CRuby delivers a trap handler's exception during the cleanup" unless RUBY_ENGINE == "ruby"
      pid = spawned_pid
      previous = trap("USR1") { raise "raised from trap handler" }
      allow(Process).to receive(:kill).and_call_original
      armed = true
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        armed ? raise("raised from a later trap handler") : kill.call(*args)
      end
      started = now
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        }.to raise_error(RuntimeError, "raised from trap handler")
      ensure
        armed = false
        trap("USR1", previous)
      end
      expect(now - started).to be_between(1, 2.5)
      expect { Process.kill(0, pid.call) }.not_to raise_error
    end

    it "keeps the trap handler's exception if the kill after it is refused" do
      skip "only CRuby delivers a trap handler's exception during the cleanup" unless RUBY_ENGINE == "ruby"
      pid = spawned_pid
      previous = trap("USR1") { raise "raised from trap handler" }
      allow(Process).to receive(:kill).and_call_original
      armed = true
      allow(Process).to receive(:kill).with("TERM", anything).and_wrap_original do |kill, *args|
        kill.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        armed ? raise(Errno::EPERM) : kill.call(*args)
      end
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        }.to raise_error(RuntimeError, "raised from trap handler")
      ensure
        armed = false
        trap("USR1", previous)
      end
      expect { Process.kill(0, pid.call) }.not_to raise_error
    end

    it "closes every descriptor if a trap handler raises while closing one" do
      skip "only CRuby delivers a trap handler's exception during the cleanup" unless RUBY_ENGINE == "ruby"
      pid = spawned_pid
      previous = trap("USR1") { raise "raised from trap handler" }
      armed = true
      allow_any_instance_of(File).to receive(:close).and_wrap_original do |close, *args|
        close.call(*args)
        Process.kill("USR1", Process.pid) if armed
      end
      before = open_descriptors
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sleep", "30", :stdout => "tmp/output.txt", :stderr => "tmp/error.txt") }
        }.to raise_error(RuntimeError, "raised from trap handler")
      ensure
        armed = false
        trap("USR1", previous)
      end
      expect(open_descriptors).to eql(before)
      expect($?.pid).to eql(pid.call)
      expect($?.termsig).to eql(Signal.list["TERM"])
    end

    it "leaves a child that does not die after KILL" do
      pid = spawned_pid
      ignore_kill = true
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with("KILL", anything).and_wrap_original do |kill, *args|
        ignore_kill ? 1 : kill.call(*args)
      end
      started = now
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sh", "-c", 'trap "" TERM; exec sleep 30') }
        }.to raise_error(Timeout::Error)
        expect(now - started).to be < 4
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
      started = now
      begin
        expect {
          Timeout.timeout(0.3) { SafeShell.execute("sleep", "30") }
        }.to raise_error(Timeout::Error)
        expect(now - started).to be < 1
        expect($?).to satisfy("be nil or describe another command") { |status| status.nil? || status.pid != pid.call }
        expect { Process.kill(0, pid.call) }.not_to raise_error
      ensure
        Process.kill("KILL", pid.call)
        Process.waitpid(pid.call)
      end
    end

    it "reaps a child that has already exited" do
      read_end, write_end = IO.pipe
      pid = spawn("true", :out => write_end)
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
    before do
      File.delete("tmp/output.txt") if File.exist?("tmp/output.txt")
    end

    it "returns only stderr when stdout is redirected" do
      output = SafeShell.execute("sh", "-c", "echo out; echo err >&2", :stdout => "tmp/output.txt")
      expect(output).to eql("err\n")
      expect(File.read("tmp/output.txt")).to eql("out\n")
    end

    it "returns nothing when both streams are redirected" do
      output = SafeShell.execute("sh", "-c", "echo out; echo err >&2", :stdout => "tmp/output.txt", :stderr => "tmp/error.txt")
      expect(output).to eql("")
      expect(File.read("tmp/output.txt")).to eql("out\n")
      expect(File.read("tmp/error.txt")).to eql("err\n")
    end

    it "lets you redirect both streams to the same file" do
      SafeShell.execute("sh", "-c", "echo out; echo err >&2; echo out2", :stdout => "tmp/output.txt", :stderr => "tmp/output.txt")
      expect(File.read("tmp/output.txt")).to eql("out\nerr\nout2\n")
    end

    it "treats two spellings of one path as the same file" do
      SafeShell.execute("sh", "-c", "echo out; echo err >&2; echo out2", :stdout => "tmp/output.txt", :stderr => "./tmp/../tmp/output.txt")
      expect(File.read("tmp/output.txt")).to eql("out\nerr\nout2\n")
    end

    it "lets you redirect stdout to a file" do
      output = SafeShell.execute("echo", "Hello, world!", :stdout => "tmp/output.txt")
      expect(output).to eql("")
      expect(File.read("tmp/output.txt")).to eql("Hello, world!\n")
    end

    it "lets you redirect stderr to a file" do
      output = SafeShell.execute("sh", "-c", "echo err >&2", :stderr => "tmp/output.txt")
      expect(output).to eql("")
      expect(File.read("tmp/output.txt")).to eql("err\n")
    end
  end

  context "options" do
    let(:untouched) { File.join(Dir.mktmpdir, "untouched.txt") }

    after { FileUtils.remove_entry(File.dirname(untouched)) }

    it "accepts a Hash of options passed with **" do
      options = { :env => { "SAFE_SHELL_SPEC" => "set" } }
      expect(SafeShell.execute("sh", "-c", "printf %s \"$SAFE_SHELL_SPEC\"", **options)).to eql("set")
    end

    it "raises ArgumentError for an option it does not know, running nothing" do
      expect(SafeShell).not_to receive(:spawn)
      expect { SafeShell.execute("pwd", :chdir => "/") }.to raise_error(ArgumentError, /chdir/)
      expect { SafeShell.execute("pwd", "stdout" => untouched) }.to raise_error(ArgumentError)
      expect { SafeShell.execute?("pwd", :chdir => "/") }.to raise_error(ArgumentError, /chdir/)
      expect { SafeShell.execute!("pwd", :chdir => "/") }.to raise_error(ArgumentError, /chdir/)
    end

    it "passes the options through execute?" do
      script = 'test "$SAFE_SHELL_SPEC" = set'
      expect(SafeShell.execute?("sh", "-c", script, :env => { "SAFE_SHELL_SPEC" => "set" })).to eql(true)
      expect(SafeShell.execute?("sh", "-c", script, :env => { "SAFE_SHELL_SPEC" => "other" })).to eql(false)
    end

    it "passes the options through execute!" do
      options = { :env => { "SAFE_SHELL_SPEC" => "set" } }
      expect(SafeShell.execute!("sh", "-c", "printf %s \"$SAFE_SHELL_SPEC\"", **options)).to eql("set")
    end

    [
      ["a symbol-keyed Hash", lambda { |path| { :stdout => path, :env => { "PATH" => "/nonexistent" } } }],
      ["a string-keyed Hash", lambda { |path| { "stdout" => path } }],
      ["a Hash subclass", lambda { |path| Class.new(Hash).new.merge!(:stdout => path) }],
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
      expect { SafeShell.execute("echo", { :stdout => untouched }, "x") }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for a Hash as the command, running nothing" do
      hash = { :env => { "SECRET" => "hunter2" } }
      expect(SafeShell).not_to receive(:spawn)
      [:execute, :execute?, :execute!].each do |method|
        expect { SafeShell.public_send(method, hash) }.to raise_error(ArgumentError, /cannot be a Hash/) { |error|
          expect(error.message).not_to include("hunter2")
        }
      end
    end

    it "keeps the Hash out of the ArgumentError message" do
      expect { SafeShell.execute("echo", { :env => { "SECRET" => "hunter2" } }) }.to raise_error(ArgumentError) { |error|
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

    it "keeps environment variables out of the exception message" do
      expect {
        SafeShell.execute!("false", :env => { "SECRET" => "hunter2" })
      }.to raise_error(SafeShell::CommandFailedException) { |error|
        expect(error.message).to include('["false"]')
        expect(error.message).not_to include("hunter2")
        expect(error.message).not_to include("SECRET")
      }
    end
  end
end
