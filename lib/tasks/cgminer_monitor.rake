namespace :cgminer_monitor do
  require 'cgminer_monitor'

  desc 'Create indexes'
  task :create_indexes do
    print "creating indexes..."
    CgminerMonitor::Document.create_indexes
    puts " done."
  end

  desc 'Delete logs'
  task :delete_logs do
    print "deleteing logs..."
    CgminerMonitor::Document::Log.delete_all
    puts " done."
  end
end
