Rails.application.routes.draw do
  # Healthcheck for load balancers and uptime monitors. Returns 200 if the app
  # is live (no auth required — handled in the rails/health controller).
  get "up" => "rails/health#show", as: :rails_health_check

  resources :nodes, only: [:index, :show, :create, :update] do
    member do
      get :edges, action: :edges
    end
  end

  resources :edges, only: [:create, :update]

  post "recall"          => "recall#create"
  post "recall/by_node"  => "recall#by_node"

  post "decay_sweep" => "maintenance#decay_sweep"
  get  "stats"       => "maintenance#stats"
end
