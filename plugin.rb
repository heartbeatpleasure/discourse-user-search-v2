# name: discourse-user-search-v2
# about: Advanced user search based on user custom fields
# version: 2.0
# authors: Chris
# url: https://github.com/heartbeatpleasure/discourse-user-search-v2

enabled_site_setting :user_search_enabled

after_initialize do
  module ::DiscourseUserSearch
    PLUGIN_NAME = "discourse-user-search".freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseUserSearch
    end
  end

  # loading controllers
  require_dependency File.expand_path(
    "../app/controllers/discourse_user_search/directory_controller.rb",
    __FILE__
  )

  require_dependency File.expand_path(
    "../app/controllers/discourse_user_search/options_controller.rb",
    __FILE__
  )

  # routes inside the engine
  DiscourseUserSearch::Engine.routes.draw do
    # searching users (already have this)
    get "/user-search" => "directory#index"

    # new endpoint for dropdown options
    get "/user-search/options" => "options#index"
  end

  # mounting engine at root
  Discourse::Application.routes.append do
    mount ::DiscourseUserSearch::Engine, at: "/"
  end
end
