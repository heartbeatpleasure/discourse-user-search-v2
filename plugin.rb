# name: discourse-user-search-v2
# about: Advanced user search based on user custom fields
# version: 2.1.0
# authors: Chris
# url: https://github.com/heartbeatpleasure/discourse-user-search-v2

enabled_site_setting :user_search_enabled

after_initialize do
  require_dependency "directory_items_controller"

  module ::DiscourseUserSearch
    PLUGIN_NAME = "discourse-user-search".freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseUserSearch
    end

    # Request-local bridge between DirectoryItemsController and DirectoryItemsQuery.
    # Keeping this request-scoped avoids thread leakage and lets core keep ownership
    # of the directory query itself.
    class DirectoryRequestContext < ActiveSupport::CurrentAttributes
      attribute :params
    end

    class << self
      attr_writer :directory_integration_available

      def directory_integration_available?
        @directory_integration_available == true
      end
    end

    module DirectoryFilters
      HB_KEYS = %i[hb_gender hb_country hb_listen hb_share].freeze
      CUSTOM_SORTS = %w[last_seen joined].freeze
      UI_SORTS = %w[last_seen username joined].freeze
      MAX_FILTER_VALUE_LENGTH = 255
      MAX_MULTI_VALUES = 20
      module_function

      def extract_directory_params(params)
        values = extract_filter_params(params)
        order = value_for(params, :order).to_s.strip
        values[:order] = order if order.present?
        values.freeze
      end

      def extract_filter_params(params)
        HB_KEYS.each_with_object({}) do |key, out|
          value = sanitize_filter_value(value_for(params, key))
          out[key] = value if value.present?
        end
      end

      def filters_present?(params)
        HB_KEYS.any? { |key| sanitize_filter_value(value_for(params, key)).present? }
      end

      def custom_sort?(order)
        CUSTOM_SORTS.include?(order.to_s)
      end

      def ui_sort?(order)
        UI_SORTS.include?(order.to_s)
      end

      def apply_to_users(scope, params)
        return scope unless SiteSetting.user_search_enabled?

        scope = apply_eligibility(scope)
        apply_custom_field_filters(scope, params)
      end

      def apply_to_directory_items(scope, params, allow_custom_filters:)
        return scope unless SiteSetting.user_search_enabled?

        # DirectoryItem does not join users by default. Add the association once
        # so eligibility and custom-field EXISTS clauses can safely reference users.id.
        scope = scope.joins(:user)
        scope = apply_eligibility(scope)
        return scope unless allow_custom_filters

        apply_custom_field_filters(scope, params)
      end

      def user_eligible?(user)
        return false if user.blank?
        return false unless user.active?
        return false if user.staged?
        return false if user.trust_level.to_i < minimum_trust_level

        suspended_till = user.suspended_till
        suspended_till.blank? || suspended_till < Time.zone.now
      end

      def csv(str)
        return [] if str.blank?

        str
          .to_s
          .split(",", MAX_MULTI_VALUES + 1)
          .first(MAX_MULTI_VALUES)
          .map { |value| sanitize_filter_value(value) }
          .reject(&:blank?)
      end

      def user_field_id_by_name(field_name)
        return nil if field_name.blank?

        # Do not cache this across requests: admins may rename/reconfigure fields
        # without restarting the application.
        ::UserField.find_by(name: field_name)&.id
      end

      def norm(value)
        sanitize_filter_value(value).downcase
      end

      def sanitize_filter_value(value)
        value.to_s.strip[0, MAX_FILTER_VALUE_LENGTH]
      end

      def filter_by_custom_field(scope, field_name, value)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || value.blank?

        custom_name = "#{User::USER_FIELD_PREFIX}#{field_id}"
        value_norm = norm(value)
        return scope if value_norm.blank?

        # EXISTS avoids duplicate directory rows if historical/imported data has
        # more than one custom-field record for the same user and field.
        scope.where(
          <<~SQL,
            EXISTS (
              SELECT 1
                FROM user_custom_fields ucf
               WHERE ucf.user_id = users.id
                 AND ucf.name = ?
                 AND LOWER(TRIM(ucf.value)) = ?
            )
          SQL
          custom_name,
          value_norm,
        )
      end

      def filter_by_custom_field_multi(scope, field_name, values)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || values.blank?

        custom_name = "#{User::USER_FIELD_PREFIX}#{field_id}"
        values_norm = Array(values).first(MAX_MULTI_VALUES).map { |value| norm(value) }.reject(&:blank?).uniq
        return scope if values_norm.blank?

        scope.where(
          <<~SQL,
            EXISTS (
              SELECT 1
                FROM user_custom_fields ucf
               WHERE ucf.user_id = users.id
                 AND ucf.name = ?
                 AND LOWER(TRIM(ucf.value)) IN (?)
            )
          SQL
          custom_name,
          values_norm,
        )
      end

      def apply_eligibility(scope)
        now = Time.zone.now

        scope
          .where(users: { active: true, staged: false })
          .where("users.trust_level >= ?", minimum_trust_level)
          .where("users.suspended_till IS NULL OR users.suspended_till < ?", now)
      end
      private_class_method :apply_eligibility

      def apply_custom_field_filters(scope, params)
        return scope unless filters_present?(params)

        scope = filter_by_custom_field(
          scope,
          SiteSetting.user_search_gender_field_name,
          value_for(params, :hb_gender),
        )
        scope = filter_by_custom_field(
          scope,
          SiteSetting.user_search_country_field_name,
          value_for(params, :hb_country),
        )
        scope = filter_by_custom_field_multi(
          scope,
          SiteSetting.user_search_listen_field_name,
          csv(value_for(params, :hb_listen)),
        )
        filter_by_custom_field_multi(
          scope,
          SiteSetting.user_search_share_field_name,
          csv(value_for(params, :hb_share)),
        )
      end
      private_class_method :apply_custom_field_filters

      def minimum_trust_level
        SiteSetting.user_search_min_trust_level.to_i.clamp(0, 4)
      end
      private_class_method :minimum_trust_level

      def value_for(params, key)
        return nil if params.blank?

        params[key] || params[key.to_s]
      end
      private_class_method :value_for
    end

    # Minimal controller integration only. Core continues to own index, query
    # construction, permissions, serialization and pagination.
    module DirectoryItemsControllerPatch
      def index
        if SiteSetting.user_search_enabled? && current_user.present?
          DirectoryRequestContext.params = DirectoryFilters.extract_directory_params(params)
        end

        super
      ensure
        DirectoryRequestContext.reset
      end

      # Core builds its load-more URL from a fixed allowlist. Preserve our hb_*
      # parameters without replacing/copying core's pagination implementation.
      def render_json_dump(obj, opts = nil)
        append_hb_filters_to_load_more!(obj) if SiteSetting.user_search_enabled? && current_user.present?
        super(obj, opts)
      end

      private

      def append_hb_filters_to_load_more!(obj)
        return unless obj.is_a?(Hash) && obj[:meta].is_a?(Hash)

        url = obj[:meta][:load_more_directory_items]
        return if url.blank?

        filters = DirectoryFilters.extract_filter_params(params)
        return if filters.blank?

        uri = URI.parse(url)
        query = Rack::Utils.parse_query(uri.query)
        filters.each { |key, value| query[key.to_s] = value }
        uri.query = query.to_query.presence
        obj[:meta][:load_more_directory_items] = uri.to_s
      rescue URI::InvalidURIError, ArgumentError
        # Never break the directory response if a future core version changes
        # the load-more URL format.
        nil
      end
    end

    # Extend only the two small query hooks needed by this plugin. Everything
    # else remains Discourse core behavior and automatically inherits future
    # permission/search/pagination fixes.
    module DirectoryItemsQueryPatch
      private

      def order_items(items, requested_order, ascending, *args, **kwargs)
        context = DirectoryRequestContext.params
        if context.nil? || !SiteSetting.user_search_enabled?
          return super(items, requested_order, ascending, *args, **kwargs)
        end

        items =
          DirectoryFilters.apply_to_directory_items(
            items,
            context,
            allow_custom_filters: user.present?,
          )

        # The custom activity/join-date sorts are available only to authenticated
        # users. Anonymous callers fall back to core, preventing activity-order
        # enumeration if a site's directory is publicly visible.
        if user.present? && DirectoryFilters.custom_sort?(requested_order)
          direction = ascending ? :asc : :desc
          user_table = User.arel_table
          directory_table = DirectoryItem.arel_table

          primary_order =
            if requested_order.to_s == "last_seen"
              Arel.sql("users.last_seen_at #{ascending ? "ASC" : "DESC"} NULLS LAST")
            else
              user_table[:created_at].public_send(direction)
            end

          return items.joins(:user).order(primary_order, directory_table[:id].asc)
        end

        # Username and every native/current/future Discourse sort stay entirely
        # inside core, including its public-user-field security restrictions.
        super(items, requested_order, ascending, *args, **kwargs)
      end

      def prioritize_user!(items, *args, **kwargs)
        context = DirectoryRequestContext.params
        return super(items, *args, **kwargs) if context.nil? || !SiteSetting.user_search_enabled?

        # Pinning the current user can bypass an hb_* filter and would also break
        # the strict ordering shown by our three UI sort modes.
        return if DirectoryFilters.filters_present?(context)
        return if DirectoryFilters.ui_sort?(context[:order])

        # Keep core pinning for native sorts only when the current user satisfies
        # the same eligibility constraints as every other directory result.
        return unless DirectoryFilters.user_eligible?(user)

        super(items, *args, **kwargs)
      end
    end
  end

  # Load controllers only after the shared filtering module exists.
  require_dependency File.expand_path(
    "app/controllers/discourse_user_search/directory_controller.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/controllers/discourse_user_search/options_controller.rb",
    __dir__,
  )

  DiscourseUserSearch::Engine.routes.draw do
    get "/user-search" => "directory#index"
    get "/user-search/options" => "options#index"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseUserSearch::Engine, at: "/"
  end

  # Fail safe: if a future Discourse version changes the two small private query
  # hooks we depend on, leave the core /u directory untouched instead of risking
  # a 500. The options endpoint exposes this capability to the theme component.
  directory_integration_available =
    ::DirectoryItemsQuery.private_method_defined?(:order_items) &&
      ::DirectoryItemsQuery.private_method_defined?(:prioritize_user!)

  ::DiscourseUserSearch.directory_integration_available = directory_integration_available

  if directory_integration_available
    ::DirectoryItemsController.prepend(::DiscourseUserSearch::DirectoryItemsControllerPatch)
    ::DirectoryItemsQuery.prepend(::DiscourseUserSearch::DirectoryItemsQueryPatch)
  else
    Rails.logger.warn(
      "[discourse-user-search-v2] DirectoryItemsQuery integration unavailable; " \
        "advanced /u filtering disabled while the core user directory remains unchanged.",
    )
  end
end
