# frozen_string_literal: true

module DiscourseUserSearch
  class DirectoryController < ::ApplicationController
    requires_plugin ::DiscourseUserSearch::PLUGIN_NAME

    before_action :ensure_logged_in

    def index
      raise Discourse::NotFound unless SiteSetting.user_search_enabled?

      page     = params.fetch(:page, 1).to_i
      page     = 1 if page <= 0
      per_page = params[:per_page].to_i
      per_page = 30 if per_page <= 0
      per_page = 100 if per_page > 100

      order    = parse_order(params[:order])
      asc      = params[:asc].nil? ? true : params[:asc].to_s == "true"

      users = base_scope

      # Enkelvoudige filters
      if params[:gender].present?
        users = filter_by_custom_field(users, SiteSetting.user_search_gender_field_name, params[:gender])
      end

      if params[:country].present?
        users = filter_by_custom_field(users, SiteSetting.user_search_country_field_name, params[:country])
      end

      # Multiple filters (listen/share) – expects CSV in the query string
      if params[:listen].present?
        values = params[:listen].split(",").map(&:strip).reject(&:blank?)
        users = filter_by_custom_field_multi(users, SiteSetting.user_search_listen_field_name, values) if values.any?
      end

      if params[:share].present?
        values = params[:share].split(",").map(&:strip).reject(&:blank?)
        users = filter_by_custom_field_multi(users, SiteSetting.user_search_share_field_name, values) if values.any?
      end

      users = apply_order(users, order, asc)

      # Defensive: prevent duplicates caused by custom-field joins / data anomalies
      users = users.distinct

      users = users
        .limit(per_page)
        .offset((page - 1) * per_page)

      render_serialized(users, ::UserCardSerializer, root: "users")
    end

    private

    # Only real, active, non-suspended accounts, with at least a set trust level
    def base_scope
      min_tl = SiteSetting.user_search_min_trust_level.to_i

      scope = User.where(active: true)
                  .where(staged: false)
                  .where("trust_level >= ?", min_tl)

      # exclude currently suspended
      now = Time.zone.now
      scope = scope.where("suspended_till IS NULL OR suspended_till < ?", now)

      scope
    end

    def parse_order(order_param)
      case order_param
      when "created"
        :created
      when "last_seen"
        :last_seen
      else
        :username
      end
    end

    def apply_order(scope, order, asc)
      direction = asc ? :asc : :desc

      case order
      when :created
        scope.order(created_at: direction)
      when :last_seen
        scope.order(last_seen_at: direction)
      else
        # username_lower is what core usually uses
        scope.order(username_lower: direction)
      end
    end

    def user_field_id_by_name(field_name)
      return nil if field_name.blank?

      @user_fields_by_name ||= ::UserField.all.index_by(&:name)
      field = @user_fields_by_name[field_name]
      field&.id
    end

    def filter_by_custom_field(scope, field_name, value)
      field_id = user_field_id_by_name(field_name)
      return scope if field_id.nil? || value.blank?

      custom_name = "user_field_#{field_id}"

      # Use EXISTS instead of JOIN to avoid duplicate rows when multiple custom-field
      # rows exist for a user (can happen with historical data / imports).
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
