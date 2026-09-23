# frozen_string_literal: true

Rails.application.routes.draw do
  get "/up", to: "rails/health#show", as: :rails_health_check
  get "/health", to: "health#show"
  root "certificates#index"
  post "/locale", to: "locales#update", as: :locale
  get "/login", to: "sessions#new", as: :login
  post "/local-login", to: "sessions#local", as: :local_login
  delete "/logout", to: "sessions#destroy", as: :logout
  get "/auth/keycloak/callback", to: "sessions#callback"
  get "/auth/failure", to: "sessions#failure"
  resources :certificates, only: %i[index show update] do
    post :export, on: :collection
    get :archive, on: :member
  end
  resources :imports, only: %i[new create]
  get "/imports/preview", to: "imports#preview", as: :import_preview
  resources :audit_events, only: :index
end
