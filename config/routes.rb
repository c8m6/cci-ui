Rails.application.routes.draw do
  get "/up", to: "rails/health#show", as: :rails_health_check
  root "certificates#index"
  get "/anmelden", to: "sessions#new", as: :login
  post "/lokale-anmeldung", to: "sessions#local", as: :local_login
  delete "/abmelden", to: "sessions#destroy", as: :logout
  get "/auth/keycloak/callback", to: "sessions#callback"
  get "/auth/failure", to: "sessions#failure"
  resources :certificates, path: "zertifikate", only: %i[index show update] do
    post :export, on: :collection
    get :archive, on: :member
  end
  resources :imports, path: "import", only: %i[new create]
  resources :audit_events, path: "auditlogs", only: :index
end
