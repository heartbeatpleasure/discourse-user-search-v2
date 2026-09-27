# frozen_string_literal: true

module DiscourseUserSearch
  class DirectoryController < ::ApplicationController
    requires_plugin ::DiscourseUserSearch::PLUGIN_NAME

    before_action :ensure_logged_in

    def index
      raise Discourse::NotFound unless SiteSetting.user_search_enabled?

      unless current_user.staff?
        RateLimiter.new(current_user, "user-search-directory", 120, 1.minute).performed!
      end

      page = params.fetch(:page, 1).to_i
      page = 1 if page <= 0

      per_page = params[:per_page].to_i
      per_page = 30 if per_page <= 0
      per_page = 100 if per_page > 100

      order = parse_order(params[:order])
      asc = params[:asc].nil? ? true : params[:asc].to_s == "true"

      filter_params = {
        hb_gender: params[:gender],
        hb_country: params[:country],
        hb_listen: params[:listen],
        hb_share: params[:share],
      }

      # Reuse exactly the same eligibility/custom-field filtering as /u so both
      # endpoints cannot drift into subtly different result sets.
      users = ::DiscourseUserSearch::DirectoryFilters.apply_to_users(User.all, filter_params)
      users = apply_order(users, order, asc)

      # Defensive against historical/custom data anomalies.
      users = users.distinct.limit(per_page).offset((page - 1) * per_page)

      render_serialized(users, ::UserCardSerializer, root: "users")
    end

    private

    def parse_order(order_param)
      case order_param.to_s
      when "created", "joined"
        :joined
      when "last_seen"
        :last_seen
      else
        :username
      end
    end

    def apply_order(scope, order, asc)
      direction = asc ? :asc : :desc
      user_table = User.arel_table

      primary_order =
        case order
        when :joined
          user_table[:created_at].public_send(direction)
        when :last_seen
          Arel.sql("users.last_seen_at #{asc ? "ASC" : "DESC"} NULLS LAST")
        else
          user_table[:username_lower].public_send(direction)
        end

      scope.order(primary_order, user_table[:id].asc)
    end
  end
end
