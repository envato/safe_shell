require 'safe_shell'
require 'pathname'
require 'timeout'

describe "SafeShell" do

  it "should return the output of the command" do
    expect(SafeShell.execute("echo", "Hello, world!")).to eql("Hello, world!\n")
  end

  it "should safely handle dangerous characters in command arguments" do
    expect(SafeShell.execute("echo", ";date")).to eql(";date\n")
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

  it "allows to add new env vars" do
    result = SafeShell.execute('env')
    expect(result).to_not include("HELLO=world")
    expect(result).to_not include("GOOD=world")

    result = SafeShell.execute('env', env: {'HELLO' => 'world', 'GOOD' => 'day'})
    expect(result).to include("HELLO=world")
    expect(result).to include("GOOD=day")
  end

  it "gives the command an empty stdin rather than blocking" do
    output = Timeout.timeout(5) { SafeShell.execute("cat") }
    expect(output).to eql("")
    expect($?.exitstatus).to eql(0)
  end

  it "should set $? to the exit status of the command" do
    SafeShell.execute("test", "a", "=", "a")
    expect($?.exitstatus).to eql(0)

    SafeShell.execute("test", "a", "=", "b")
    expect($?.exitstatus).to eql(1)
  end

  it "should handle a Pathname object passed as an argument" do
    expect { SafeShell.execute("ls", Pathname.new("/tmp")) }.not_to raise_error
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

  context "output redirection" do
    before do
      File.delete("tmp/output.txt") if File.exist?("tmp/output.txt")
    end

    it "should let you redirect stdout to a file" do
      SafeShell.execute("echo", "Hello, world!", :stdout => "tmp/output.txt")
      expect(File.exist?("tmp/output.txt")).to eql(true)
      expect(File.read("tmp/output.txt")).to eql("Hello, world!\n")
    end

    it "should let you redirect stderr to a file" do
      SafeShell.execute("cat", "tmp/nonexistent-file", :stderr => "tmp/output.txt")
      expect(File.exist?("tmp/output.txt")).to eql(true)
      expect(File.read("tmp/output.txt")).to eql("cat: tmp/nonexistent-file: No such file or directory\n")
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
