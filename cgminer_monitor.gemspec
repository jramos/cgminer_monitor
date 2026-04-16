# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cgminer_monitor/version'

Gem::Specification.new do |spec|
  spec.name          = "cgminer_monitor"
  spec.version       = CgminerMonitor::VERSION
  spec.authors       = ["Justin Ramos"]
  spec.email         = ["justin.ramos@gmail.com"]
  spec.summary       = "A monitor for cgminer instances."
  spec.description   = "Periodically polls cgminer instances and stores device, pool, " \
                       "and summary data to MongoDB. Provides an HTTP API for querying " \
                       "historical and current miner state."
  spec.homepage      = "https://github.com/jramos/cgminer_monitor"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob([
                          "lib/**/*.rb",
                          "lib/**/*.yml",
                          "bin/*",
                          "README.md",
                          "LICENSE.txt",
                          "CHANGELOG.md",
                          "cgminer_monitor.gemspec"
                        ])
  spec.executables   = ["cgminer_monitor"]
  spec.require_paths = ["lib"]

  spec.add_dependency "cgminer_api_client", "~> 0.3.0"
  spec.add_dependency "mongoid",            "~> 9.0"
  spec.add_dependency "puma",               ">= 6.0"
  spec.add_dependency "rack-cors",          "~> 2.0"
  spec.add_dependency "sinatra",            ">= 4.0"
end
