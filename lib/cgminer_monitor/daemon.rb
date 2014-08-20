module CgminerMonitor
  class Daemon
    def self.available_commands
      [:start, :stop, :restart, :status, :version]
    end

    # Checks to see if the current process is the child process and if not
    # will update the pid file with the child pid.
    def self.start(pidfile = 'tmp/pids/cgminer_monitor.pid', outfile = 'log/cgminer_monitor.log', errfile = 'log/cgminer_monitor.error.log')
      pid = fork do
        $0 = "cgminer_monitor"
        Signal.trap("HUP")  { exit }
        Signal.trap("INT")  { exit }
        Signal.trap("QUIT") { exit }
        redirect(outfile, errfile)

        loop do
          start = Time.now

          begin
            CgminerMonitor::Logger.new.log!
          rescue => e
            $stderr.puts "#{e.class}: #{e}"
          end

          duration = Time.now - start

          if duration < CgminerMonitor::Logger.log_interval
            sleep(CgminerMonitor::Logger.log_interval - duration)
          else
            sleep(CgminerMonitor::Logger.log_interval)
          end
        end

        exit(0)
      end

      unless pid.nil?
        raise "Fork failed" if pid == -1
        write(pid, pidfile)
        exit(0)
      end
    end

    # Try and read the existing pid from the pid file and signal the
    # process. Returns true for a non blocking status.
    def self.stop(pidfile = 'tmp/pids/cgminer_monitor.pid')
      opid = open(pidfile).read.strip.to_i
      Process.kill "HUP", opid
      File.delete(pidfile)
      true
    rescue Errno::ENOENT
      $stdout.puts "#{pidfile} did not exist: Errno::ENOENT"
      true
    rescue Errno::ESRCH
      $stdout.puts "The process #{opid} did not exist: Errno::ESRCH"
      true
    rescue Errno::EPERM
      $stderr.puts "Lack of privileges to manage the process #{opid}: Errno::EPERM"
      false
    rescue ::Exception => e
      $stderr.puts "While signaling the PID, unexpected #{e.class}: #{e}"
      false
    end

    def self.restart(pidfile = 'tmp/pids/cgminer_monitor.pid', outfile = 'log/cgminer_monitor.log', errfile = 'log/cgminer_monitor.error.log')
      self.stop(pidfile) unless self.status == :stopped
      self.start(pidfile, outfile, errfile)
    end

    def self.status(pidfile = 'tmp/pids/cgminer_monitor.pid')
      begin
        opid = open(pidfile).read.strip.to_i
        Process.getpgid(opid)
        :running
      rescue
        :stopped
      end
    end

    def self.version
      CgminerMonitor.version
    end

    private

    # Attempts to write the pid of the forked process to the pid file.
    def self.write(pid, pidfile = 'tmp/pids/cgminer_monitor.pid')
      File.open pidfile, "w" do |f|
        f.write pid
      end
    rescue ::Exception => e
      $stderr.puts "While writing the PID to file, unexpected #{e.class}: #{e}"
      Process.kill "HUP", pid
    end
  
    # Send stdout and stderr to log files for the child process
    def self.redirect(outfile = 'log/cgminer_monitor.log', errfile = 'log/cgminer_monitor.error.log')
      $stdin.reopen '/dev/null'
      out = File.new outfile, "a"
      err = File.new errfile, "a"
      $stdout.reopen out
      $stderr.reopen err
      $stdout.sync = $stderr.sync = true
    end
  end
end