Rails.application.routes.draw do
  get "/health", to: "health#show"

  namespace :api do
    namespace :v1 do
      resources :events, only: [:create]
      get "/shipments", to: "shipments#index"
      get "/shipments/:reference/timeline", to: "shipments#timeline"
    end
  end
end
