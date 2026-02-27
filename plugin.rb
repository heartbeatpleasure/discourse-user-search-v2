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

    # endpoint for dropdown options
    get "/user-search/options" => "options#index"
  end

  # mounting engine at root
  Discourse::Application.routes.append do
    mount ::DiscourseUserSearch::Engine, at: "/"
  end

  # ------------------------------------------------------------
  # Server-side filtering and sorting for /u (User Directory)
  #
  # The User Card Directory plugin builds the cards from the
  # /directory_items.json endpoint. We apply filters server-side to
  # avoid duplicates/missing users and to make pagination stable.
  # ------------------------------------------------------------

  require_dependency "directory_items_controller"

  module ::DiscourseUserSearch
    module DirectoryFilters
      HB_KEYS = %i[hb_gender hb_country hb_listen hb_share].freeze
      module_function

      def filters_present?(params)
        HB_KEYS.any? { |k| params[k].present? }
      end

      def apply(scope, params)
        return scope unless SiteSetting.user_search_enabled?

        # Always constrain directory results to:
        # - active, non-staged users
        # - trust level >= configured minimum
        # - not currently suspended
        min_tl = SiteSetting.user_search_min_trust_level.to_i
        now = Time.zone.now

        scope =
          scope
            .joins(:user)
            .where(users: { active: true, staged: false })
            .where("users.trust_level >= ?", min_tl)
            .where("users.suspended_till IS NULL OR users.suspended_till < ?", now)

        # Only apply custom-field filters when hb_* params are present.
        return scope unless filters_present?(params)

        scope = filter_by_custom_field(scope, SiteSetting.user_search_gender_field_name, params[:hb_gender])
        scope = filter_by_custom_field(scope, SiteSetting.user_search_country_field_name, params[:hb_country])

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

      def norm(val)
        val.to_s.strip.downcase
      end

      def filter_by_custom_field(scope, field_name, value)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || value.blank?

        custom_name = "user_field_#{field_id}"
        value_norm = norm(value)
        return scope if value_norm.blank?

        # Use EXISTS to avoid duplicates when historical data has multiple rows.
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
          value_norm
        )
      end

      def filter_by_custom_field_multi(scope, field_name, values)
        field_id = user_field_id_by_name(field_name)
        return scope if field_id.nil? || values.blank?

        custom_name = "user_field_#{field_id}"
        values_norm = Array(values).map { |v| norm(v) }.reject(&:blank?)
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
          values_norm
        )
      end
    end
  end

  module ::DiscourseUserSearch
    module DirectoryItemsControllerPatch
      # Apply our baseline constraints + hb_* filtering after core's exclude_groups handling.
      def apply_exclude_groups_filter(result)
        result = super
        ::DiscourseUserSearch::DirectoryFilters.apply(result, params)
      end

      # Support custom sort orders and disable "pin current user" behavior when:
      # - hb_* filters are active (pinning can bypass filters)
      # - our custom ordering is used (pinning breaks sort expectations)
      def index
        order = params[:order].presence
        needs_custom_index =
          order.blank? ||
            ::DiscourseUserSearch::DirectoryFilters.filters_present?(params) ||
            %w[last_seen joined username].include?(order)

        return super unless needs_custom_index
        index_with_hb_order
      end

      # Ensure pagination keeps hb_* params, so "Load more" stays filtered.
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

      private

      # Copy of core DirectoryItemsController#index with minimal changes:
      # - default order is last_seen
      # - support order=last_seen and order=joined
      # - disable the "pin current user" insertion
      def index_with_hb_order
        unless SiteSetting.enable_user_directory?
          raise Discourse::InvalidAccess.new(:enable_user_directory)
        end

        period = params.require(:period)
        period_type = DirectoryItem.period_types[period.to_sym]
        raise Discourse::InvalidAccess.new(:period_type) unless period_type

        result = DirectoryItem.where(period_type: period_type).includes(user: :user_custom_fields)

        if params[:group]
          group = Group.find_by(name: params[:group])
          raise Discourse::InvalidParameters.new(:group) if group.blank?

          guardian.ensure_can_see!(group)
          guardian.ensure_can_see_group_members!(group)

          result = result.includes(user: :groups).where(users: { groups: { id: group.id } })
        else
          result = result.includes(user: :primary_group)
        end

        result = apply_exclude_groups_filter(result)

        if params[:exclude_usernames]
          result =
            result
              .references(:user)
              .where.not(users: { username: params[:exclude_usernames].split(",") })
        end

        order = params[:order].presence || "last_seen"
        dir = params[:asc] ? "ASC" : "DESC"
        active_directory_column_names = DirectoryColumn.active_column_names

        if order == "last_seen"
          result =
            result
              .references(:user)
              .order("users.last_seen_at #{dir} NULLS LAST, directory_items.id")
        elsif order == "joined"
          result =
            result
              .references(:user)
              .order("users.created_at #{dir}, directory_items.id")
        elsif order == "username"
          result =
            result
              .references(:user)
              .order("users.username #{dir}, directory_items.id")
        elsif active_directory_column_names.include?(order.to_sym)
          result = result.order("directory_items.#{order} #{dir}, directory_items.id")
        else
          # Ordering by user field value
          user_field = UserField.find_by(name: params[:order])
          if user_field
            result =
              result
                .references(:user)
                .joins(
                  "LEFT OUTER JOIN user_custom_fields ON user_custom_fields.user_id = users.id AND user_custom_fields.name = 'user_field_#{user_field.id}'"
                )
                .order(
                  "user_custom_fields.name = 'user_field_#{user_field.id}' ASC, user_custom_fields.value #{dir}"
                )
          end
        end

        result = result.includes(:user_stat) if period_type == DirectoryItem.period_types[:all]

        page = fetch_int_from_params(:page, default: 0, max: ::DirectoryItemsController::PAGE_LIMIT)
        user_ids = nil

        if params[:name].present?
          user_ids =
            UserSearch.new(params[:name], { include_staged_users: true, limit: 200 })
              .search
              .pluck(:id)

          if user_ids.present?
            # core behavior: include yourself if there are matches
            user_ids << current_user.id if current_user && result.dup.where(user_id: user_ids).exists?
            result = result.where(user_id: user_ids)
          else
            result = result.where("false")
          end
        end

        if params[:username]
          user_id = User.where(username_lower: params[:username].to_s.downcase).pick(:id)
          if user_id
            result = result.where(user_id: user_id)
          else
            result = result.where("false")
          end
        end

        limit = fetch_limit_from_params(default: ::DirectoryItemsController::PAGE_SIZE, max: ::DirectoryItemsController::PAGE_SIZE)
        result_count = result.count
        result = result.limit(limit).offset(limit * page).to_a

        more_params =
          params
            .slice(:period, :order, :asc, :group, :user_field_ids, :plugin_column_ids, :name)
            .permit!
        more_params[:order] ||= order
        more_params[:page] = page + 1

        load_more_uri = URI.parse(directory_items_path(more_params))
        load_more_directory_items_json = "#{load_more_uri.path}.json?#{load_more_uri.query}"

        last_updated_at = DirectoryItem.last_updated_at(period_type)

        serializer_opts = {}
        if params[:user_field_ids]
          serializer_opts[:user_custom_field_map] = {}
          allowed_field_ids =
            if guardian.is_staff?
              UserField.pluck(:id)
            else
              UserField.public_fields.pluck(:id)
            end

          user_field_ids = params[:user_field_ids].split("|").map(&:to_i) & allowed_field_ids
          user_field_ids.each do |user_field_id|
            serializer_opts[:user_custom_field_map]["#{User::USER_FIELD_PREFIX}#{user_field_id}"] =
              user_field_id
          end
        end

        if params[:plugin_column_ids]
          serializer_opts[:plugin_column_ids] = params[:plugin_column_ids]&.split("|")&.map(&:to_i)
        end

        serializer_opts[:attributes] = active_directory_column_names
        serializer_opts[:searchable_fields] = UserField.where(searchable: true) if serializer_opts[:user_custom_field_map].present?

        serialized = serialize_data(result, DirectoryItemSerializer, serializer_opts)

        render_json_dump(
          directory_items: serialized,
          meta: {
            last_updated_at: last_updated_at,
            total_rows_directory_items: result_count,
            load_more_directory_items: load_more_directory_items_json,
          },
        )
      end
    end
  end

  ::DirectoryItemsController.prepend(::DiscourseUserSearch::DirectoryItemsControllerPatch)
end
