require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "SafeShell" do

  it "should return the output of the command" do
    SafeShell.execute("echo", "Hello, world!").should == "Hello, world!\n"
  end

  it "should set $? to the exit status of the command" do
    SafeShell.execute("test", "a", "=", "a")
    $?.exitstatus.should == 0

    SafeShell.execute("test", "a", "=", "b")
    $?.exitstatus.should == 1
  end

  it "should safely handle dangerous characters in command arguments" do
    SafeShell.execute("echo", ";date").should == ";date\n"
  end

end
