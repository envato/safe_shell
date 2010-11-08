require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "SafeShell" do

  it "should return the output of the command" do
    SafeShell.execute("echo", "Hello, world!").should == "Hello, world!\n"
  end

  it "should safely handle dangerous characters in command arguments" do
    SafeShell.execute("echo", ";date").should == ";date\n"
  end

  it "should set $? to the exit status of the command" do
    SafeShell.execute("test", "a", "=", "a")
    $?.exitstatus.should == 0

    SafeShell.execute("test", "a", "=", "b")
    $?.exitstatus.should == 1
  end

  context "output redirection" do
    before do
      File.delete("tmp/output.txt") if File.exists?("tmp/output.txt")
    end

    it "should let you redirect stdout to a file" do
      SafeShell.execute("echo", "Hello, world!", :stdout => "tmp/output.txt")
      File.exists?("tmp/output.txt").should be_true
      File.read("tmp/output.txt").should == "Hello, world!\n"
    end

    it "should let you redirect stderr to a file" do
      SafeShell.execute("cat", "tmp/nonexistent-file", :stderr => "tmp/output.txt")
      File.exists?("tmp/output.txt").should be_true
      File.read("tmp/output.txt").should == "cat: tmp/nonexistent-file: No such file or directory\n"
    end
  end

end
