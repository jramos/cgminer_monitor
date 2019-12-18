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
  spec.homepage      = "https://github.com/jramos/cgminer_monitor"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "cgminer_api_client",    "~> 0.2.6",    ">= 0.2.6"
  spec.add_dependency "mongoid",               "~> 7.0.0",    ">= 7.0.0"
  spec.add_dependency "rails",                 "~> 5.1.0",    ">= 5.1.0"
end
