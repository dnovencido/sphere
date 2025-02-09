# frozen_string_literal: true

class Admins::RegistrationsController < Devise::RegistrationsController
  def after_sign_up_path_for(resource)
    flash[:notice] = "Welcome! You have signed up successfully." 
    stored_location_for(resource) || admins_dashboard_index_path
  end  
end
