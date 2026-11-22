# SafeShell

SafeShell lets you execute shell commands and get the resulting output, but without the security problems of Ruby's backtick operator.

## Usage

Install gem:

```sh
gem install safe_shell
```

Use gem:

```ruby
require 'safe_shell'
SafeShell.execute("echo", "Hello, world!")
```

SafeShell sets the $? operator to the process status, in the same manner as the backtick operator.

If the call is interrupted, by a timeout or a signal, SafeShell sends the command TERM, then KILL if it is still running a second later, and reaps it, so $? describes the terminated command. The call returns once the command has been reaped, normally up to a second after the interruption. Only the command's own process is signalled, not any processes it started. The exceptions:

- A command that has changed user cannot be signalled and is left running; $? is nil or unchanged from the previous command.
- A command that has not died a second after KILL is left unreaped; $? is nil or unchanged from the previous command.
- A command that something else in the process has already reaped is not signalled; $? is nil or unchanged from the previous command.
- On CRuby, an exception raised from a signal handler installed with `trap` while the command is being waited on cuts the wait short and the command is killed at once; landing elsewhere in the cleanup, it is delivered after the ordinary TERM and KILL. JRuby delivers it after the cleanup.
- Deferred interrupts are delivered while the command is being waited on, even inside a caller's `Thread.handle_interrupt(... => :never)`.

```ruby
# Send stdout and stderr to files:
SafeShell.execute("echo", "Hello, world!", :stdout => "output.txt", :stderr => "error.txt")

# Send additional environment variables:
SafeShell.execute("echo", "Hello, world!", :env => { 'name' => 'john', 'foo' => 'bar' })

# Return true if the command exits with a zero status:
SafeShell.execute?("echo", "Hello, world!")

# Raise an exception if the command exits with a non-zero status:
SafeShell.execute!("echo", "Hello, world!")
```

The returned String holds everything the command writes to stdout and stderr, interleaved as the command writes them. Redirecting one stream to a file leaves the other in the returned String, so with only `:stdout` redirected the return value is the command's stderr; with both redirected it is empty. Each file is truncated on every call, and the two paths must differ: the same path for both loses output. Keys and values in `:env` are Strings, and a nil value unsets the variable for the command. Option keys other than `:stdout`, `:stderr` and `:env` are ignored.

## Why?

If you use backticks to process a file supplied by a user, a carefully crafted filename could allow execution of an arbitrary command:

```ruby
file = ";blah"
`echo #{file}`
sh: blah: command not found
=> "\n"
```

SafeShell solves this.

```ruby
SafeShell.execute("echo", file)
=> ";blah\n"
```

The first argument is always the program to run and is never passed to a shell, even when it is the only argument. Each remaining argument reaches the program as a single, literal argument. A command string such as `"echo #{file}"` is therefore looked up as a program named `echo #{file}` and fails with `Errno::ENOENT`; pass the program and its arguments separately instead.

A program that cannot be found raises `Errno::ENOENT` from all three methods, since no command ran and there is no status to report: `execute?` does not return false and `execute!` does not raise `CommandFailedException`.

## Compatibility

Tested on every push against Ruby 3.0 through 4.0, JRuby, and TruffleRuby, on Linux. The gem requires Ruby 3.0 or newer. It is not tested on Windows.

## Test

```sh
bundle exec rake
````

## Developing

* Fork the project.
* Make your feature addition or bug fix.
* Add tests for it. This is important so I don't break it in a
  future version unintentionally.
* Commit, do not mess with rakefile, version, or history.
  (if you want to have your own version, that is fine but bump version in a commit by itself I can ignore when I pull)
* Send me a pull request. Bonus points for topic branches.

## Status

In use on at least one big site, so should be pretty solid. There's not much to it, so I'm not expecting there'll be many releases.

## Copyright

Copyright (c) 2010 - 2015 Envato, Ian Leitch, & Pete Yandell. See LICENSE for details.
