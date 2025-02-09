class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
  layout :set_layout
  
  def after_sign_in_path_for(resource)
    stored_location_for(resource) || admins_dashboard_index_path
  end

  def set_layout
    if current_admin
      "application_admin"
    else
      "application"
    end
  end 

end
