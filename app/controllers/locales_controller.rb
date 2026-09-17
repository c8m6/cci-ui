class LocalesController < ApplicationController
  skip_before_action :require_identity

  def update
    locale = params[:locale].to_s
    return head :unprocessable_entity unless locale.empty? || I18n.available_locales.map(&:to_s).include?(locale)

    if locale.empty?
      cookies.delete(:locale)
    else
      cookies.permanent.signed[:locale] = { value: locale, httponly: true,
        secure: request.ssl?, same_site: :lax }
    end
    # Return only to local paths. Never redirect to a supplied host.
    target = params[:return_to].to_s
    target = root_path unless target.start_with?("/") && !target.start_with?("//") && !target.match?(/[\\\r\n]/)
    redirect_to target, status: :see_other, allow_other_host: false
  end
end
