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

  # ------------------------------------------------------------
  # Server-side filtering for /u (User Directory)
  #
  # The User Card Directory plugin builds the cards from the
  # /directory_items.json endpoint. Previously we hid cards client-side,
  # which caused duplicates / missing users. We now apply filters on the
  # server by patching DirectoryItemsController.
  # ------------------------------------------------------------

  require_dependency "directory_items_controller"

  module ::DiscourseUserSearch
    module DirectoryFilters
      HB_KEYS = %i[hb_gender hb_country hb_listen hb_share].freeze

      module_function

      def apply(scope, params)
        return scope unless SiteSetting.user_search_enabled?

        # Only apply on the Users Directory route (/u) where these params are used.
        return scope unless HB_KEYS.any? { |k| params[k].present? }

        # Constrain to active, non-staged, non-suspended users with a minimum TL.
        min_tl = SiteSetting.user_search_min_trust_level.to_i
        now = Time.zone.now

        scope = scope
          .joins(:user)
          .where(users: { active: true, staged: false })
          .where("users.trust_level >= ?", min_tl)
          .where("users.suspended_till IS NULL OR users.suspended_till < ?", now)

        # Exact match filters
        scope = filter_by_custom_field(scope, SiteSetting.user_search_gender_field_name, params[:hb_gender])
        scope = filter_by_custom_field(scope, SiteSetting.user_search_country_field_name, params[:hb_country])

        # Multi-value filters (CSV)
        scope = filter_by_custom_field_multi(scope, SiteSetting.user_search_listen_field_name, csv(params[:hb_listen]))
        scope = filter_by_custom_field_multi(scope, SiteSetting.user_search_share_field_name, csv(params[:hb_share]))

        scope
      end

      def csv(str)
        return [] if str.blank?
        str.to_s.split(",").map(&:strip).reject(&:blank?)
      end

      def user_field_id_by_name(field_name)
        return nil if field_name.blank?
        @user_fields_by_name ||= ::UserField.all.index_by(&:name)
        @user_fields_by_name[field_name]&.id
      end

      def filter_by_custom_field(scope, field_name, value)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || value.blank?

        custom_name = "user_field_#{field_id}"

        # Use EXISTS to avoid duplicates when historical data has multiple rows.
        scope.where(
          <<~SQL,
            EXISTS (
              SELECT 1
                FROM user_custom_fields ucf
               WHERE ucf.user_id = users.id
                 AND ucf.name = ?
                 AND ucf.value = ?
            )
          SQL
          custom_name,
          value
        )
      end

      def filter_by_custom_field_multi(scope, field_name, values)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || values.blank?

        custom_name = "user_field_#{field_id}"

        scope.where(
          <<~SQL,
            EXISTS (
              SELECT 1
                FROM user_custom_fields ucf
               WHERE ucf.user_id = users.id
                 AND ucf.name = ?
                 AND ucf.value IN (?)
            )
          SQL
          custom_name,
          values
        )
      end
    end
  end

  module ::DiscourseUserSearch
    module DirectoryItemsControllerPatch
      # Hook into core's query building.
      def apply_exclude_groups_filter(result)
        result = super
        ::DiscourseUserSearch::DirectoryFilters.apply(result, params)
      end

      # Ensure pagination keeps our hb_* params, so "Load more" stays filtered.
      def render_json_dump(obj, *args)
        if obj.is_a?(Hash) && obj[:meta].is_a?(Hash)
          url = obj[:meta][:load_more_directory_items]
          if url.present?
            begin
              uri = URI.parse(url)
              qp = Rack::Utils.parse_query(uri.query)

              ::DiscourseUserSearch::DirectoryFilters::HB_KEYS.each do |k|
                v = params[k]
                qp[k.to_s] = v if v.present?
              end

              uri.query = qp.to_query.presence
              obj[:meta][:load_more_directory_items] = uri.to_s
            rescue
              # If URI parsing fails, don't break the response.
            end
          end
        end

        super(obj, *args)
      end
    end
  end

  ::DirectoryItemsController.prepend(::DiscourseUserSearch::DirectoryItemsControllerPatch)
end
