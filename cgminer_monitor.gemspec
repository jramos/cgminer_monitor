# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cgminer_monitor/version'

Gem::Specification.new do |spec|
  spec.name          = "cgminer_monitor"
  spec.version       = CgminerMonitor::VERSION
  spec.authors       = ["Justin Ramos"]
  spec.email         = ["justin.ramos@gmail.com"]
  spec.summary       = %q{A monitor for cgminer instances.}
  spec.description   = %q{}
  spec.homepage      = "http://www.ramosresearch.com"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "cgminer_api_client",    "~> 0.2.1"
  spec.add_dependency "mongoid",               "= 4.0.0"
  spec.add_dependency "rails",                 "= 4.1.4"
  spec.add_dependency "rake",                  "~> 10.0"

  spec.add_development_dependency "bundler",   "~> 1.6"
  spec.add_development_dependency "pry",       "~> 0.9.12.0"
  spec.add_development_dependency "rspec",     "~> 3.0.0"
end
