CgminerMonitor::Engine.routes.draw do
  namespace :cgminer_monitor do
    namespace :api do
      namespace :v1 do
        match 'graph_data', to: 'graph_data#index', via: [:get]
      end
    end
  end
end