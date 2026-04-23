# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# Ruby 4.0 removed ostruct from default gems; Mongoid 9 hasn't updated.
gem 'ostruct' if RUBY_VERSION >= '3.5'

group :development do
  gem 'bundler-audit', '>= 0.9'
  gem 'rack-test',     '>= 2.1'
  gem 'rake',          '>= 13.2'
  gem 'rspec',         '>= 3.13'
  gem 'rubocop',       '>= 1.60'
  gem 'rubocop-rake',  '>= 0.6'
  gem 'rubocop-rspec', '>= 3.0'
  gem 'simplecov',     '>= 0.22'
end
