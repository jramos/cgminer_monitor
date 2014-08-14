namespace :cgminer_monitor do
  require 'cgminer_monitor'

  desc 'Create indexes'
  task :create_indexes do
    print "creating indexes..."
    CgminerMonitor::Document.create_indexes
    puts " done."
  end
end
