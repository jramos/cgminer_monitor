CgminerMonitor::Engine.routes.draw do
  namespace :cgminer_monitor do
    namespace :api do
      namespace :v1 do
        match 'graph_data/devs',    to: 'graph_data#devs',    via: [:get]
        match 'graph_data/pools',   to: 'graph_data#pools',   via: [:get]
        match 'graph_data/stats',   to: 'graph_data#stats',   via: [:get]
        match 'graph_data/summary', to: 'graph_data#summary', via: [:get]
      end
    end
  end
end