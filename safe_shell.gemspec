$:.push File.expand_path("../lib", __FILE__)
require "safe_shell/version"

Gem::Specification.new do |s|
  s.name        = "safe_shell"
  s.version     = SafeShell::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Envato", "Ian Leitch", "Pete Yandell"]
  s.email       = ["pete@notahat.com"]
  s.homepage    = "https://github.com/envato/#{s.name}"
  s.summary     = "Safely execute shell commands and get their output."
  s.description = "Execute shell commands and get the resulting output, but without the security problems of Ruby's backtick operator."
  s.license     = "MIT"

  s.add_development_dependency "rake"
  s.add_development_dependency "rspec"

  s.files            = `git ls-files`.split("\n")
  s.require_paths    = ["lib"]
  s.extra_rdoc_files = ["LICENSE", "README.md"]

  s.required_ruby_version = ">= 2.0.0"
end
