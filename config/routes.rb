CgminerMonitor::Engine.routes.draw do
  namespace :cgminer_monitor do
    namespace :api do
      namespace :v1 do
        namespace :graph_data do
          get 'local_hashrate'
          get 'local_temperature'

          get 'miner_hashrate'
          get 'miner_temperature'
        end
      end
    end
  end
end