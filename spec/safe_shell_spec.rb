require 'safe_shell'
require 'pathname'

describe "SafeShell" do

  it "should return the output of the command" do
    expect(SafeShell.execute("echo", "Hello, world!")).to eql("Hello, world!\n")
  end

  it "should safely handle dangerous characters in command arguments" do
    expect(SafeShell.execute("echo", ";date")).to eql(";date\n")
  end

  it "allows to add new env vars" do
    expect(SafeShell.execute('env')).to_not include("HELLO=world")
    expect(SafeShell.execute('env', env: {'HELLO' => 'world'})).to include("HELLO=world")
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

  context "output redirection" do
    before do
      File.delete("tmp/output.txt") if File.exists?("tmp/output.txt")
    end

    it "should let you redirect stdout to a file" do
      SafeShell.execute("echo", "Hello, world!", :stdout => "tmp/output.txt")
      expect(File.exists?("tmp/output.txt")).to eql(true)
      expect(File.read("tmp/output.txt")).to eql("Hello, world!\n")
    end

    it "should let you redirect stderr to a file" do
      SafeShell.execute("cat", "tmp/nonexistent-file", :stderr => "tmp/output.txt")
      expect(File.exists?("tmp/output.txt")).to eql(true)
      expect(File.read("tmp/output.txt")).to eql("cat: tmp/nonexistent-file: No such file or directory\n")
    end
  end

  context ".execute!" do
    it "returns the output of the command" do
      expect(SafeShell.execute!("echo", "Hello, world!")).to eql("Hello, world!\n")
    end

    it "raises an exception of the command fails" do
      expect {
        SafeShell.execute!("test", "a", "=", "b")
      }.to raise_error(SafeShell::CommandFailedException)
    end
  end

end
