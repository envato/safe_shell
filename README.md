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

## Compatibility

Tested with Ruby 2.0.0 or newer, but it should be happy on pretty much any Ruby version. Maybe not so much on Windows.

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
