require 'rspec/core/rake_task'

namespace :cgminer_monitor do
  require 'cgminer_monitor'

  desc 'Create indexes'
  task :create_indexes do
    CgminerMonitor::Document.document_types.each do |klass|
      print "creating indexes for #{klass.to_s}..."
        klass.create_indexes
      puts " done."
    end
  end
end

