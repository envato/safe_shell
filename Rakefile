require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "safe_shell"
    gem.summary = %Q{Safely execute shell commands and get their output.}
    gem.description = %Q{Execute shell commands and get the resulting output, but without the security problems of Ruby's backtick operator.}
    gem.email = "pete@notahat.com"
    gem.homepage = "http://github.com/envato/safe_shell"
    gem.authors = ["Envato", "Ian Leitch", "Pete Yandell"]
    gem.add_development_dependency "rspec", ">= 1.2.9"
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)
task :spec => :check_dependencies
task :default => :spec

RSpec::Core::RakeTask.new(:rcov => :spec) do |spec|
  spec.rcov = true
end

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "safe_shell #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end
