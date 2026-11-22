# frozen_string_literal: true

$LOAD_PATH.push File.expand_path("lib", __dir__)
require "safe_shell/version"

Gem::Specification.new do |s|
  s.name        = "safe_shell"
  s.version     = SafeShell::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Envato", "Ian Leitch", "Pete Yandell"]
  s.email       = ["rubygems@envato.com"]
  s.homepage    = "https://github.com/envato/#{s.name}"
  s.summary     = "Safely execute shell commands and get their output."
  s.description = "Execute shell commands and get the resulting output, but without the security problems of Ruby's backtick operator."
  s.license     = "MIT"
  s.metadata    = {
    "allowed_push_host" => "https://rubygems.org",
    "homepage_uri"      => s.homepage,
    "source_code_uri"   => "#{s.homepage}/tree/v#{s.version}",
    "bug_tracker_uri"   => "#{s.homepage}/issues",
    "changelog_uri"     => "#{s.homepage}/releases/tag/v#{s.version}",
  }

  s.files            = Dir["lib/**/*.rb"] + ["LICENSE", "README.md"]
  s.require_paths    = ["lib"]
  s.extra_rdoc_files = ["LICENSE", "README.md"]

  s.required_ruby_version = ">= 3.0.0"
end
