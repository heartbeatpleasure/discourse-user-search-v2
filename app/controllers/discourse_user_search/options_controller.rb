# frozen_string_literal: true

module DiscourseUserSearch
  class OptionsController < ::ApplicationController
    requires_plugin ::DiscourseUserSearch::PLUGIN_NAME

    before_action :ensure_logged_in

    def index
      render json: {
        gender: options_for(SiteSetting.user_search_gender_field_name),
        country: options_for(SiteSetting.user_search_country_field_name),
        listen: options_for(SiteSetting.user_search_listen_field_name),
        share: options_for(SiteSetting.user_search_share_field_name)
      }
    end

    private

    def options_for(field_name)
      return [] if field_name.blank?

      field = ::UserField.find_by(name: field_name)
      return [] if field.nil?

      # Do not sort on :position, that column does not always exist
      field.user_field_options.order(:id).pluck(:value)
    end
  end
end
