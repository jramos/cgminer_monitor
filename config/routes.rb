CgminerMonitor::Engine.routes.draw do
  namespace :cgminer_monitor do
    namespace :api do
      namespace :v1 do
        namespace :log do
          get 'last_entries'
        end

        get 'ping' => 'ping#index'

        namespace :graph_data do
          get 'local_availability'
          get 'local_hashrate'
          get 'local_temperature'

          get 'miner_availability'
          get 'miner_hashrate'
          get 'miner_temperature'
        end
      end
    end
  end
end