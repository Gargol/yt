require 'yt/collections/base'

module Yt
  module Collections
    # @private
    class Reports < Base
      DIMENSIONS = Hash.new({name: 'day', parse: ->(day, *values) { @metrics.keys.zip(values.map{|v| {Date.iso8601(day) => v}}).to_h} }).tap do |hash|
        hash[:month] = {name: 'month', parse: ->(month, *values) { @metrics.keys.zip(values.map{|v| {Range.new(Date.strptime(month, '%Y-%m').beginning_of_month, Date.strptime(month, '%Y-%m').end_of_month) => v} }).to_h} }
        hash[:range] = {parse: ->(*values) { @metrics.keys.zip(values.map{|v| {total: v}}).to_h } }
        hash[:traffic_source] = {name: 'insightTrafficSourceType', parse: ->(source, *values) { @metrics.keys.zip(values.map{|v| {TRAFFIC_SOURCES.key(source) => v}}).to_h} }
        hash[:playback_location] = {name: 'insightPlaybackLocationType', parse: ->(location, *values) { @metrics.keys.zip(values.map{|v| {PLAYBACK_LOCATIONS.key(location) => v}}).to_h} }
        hash[:embedded_player_location] = {name: 'insightPlaybackLocationDetail', parse: ->(url, *values) {@metrics.keys.zip(values.map{|v| {url => v}}).to_h} }
        hash[:related_video] = {name: 'insightTrafficSourceDetail', parse: ->(video_id, *values) { @metrics.keys.zip(values.map{|v| {video_id => v}}).to_h} }
        hash[:search_term] = {name: 'insightTrafficSourceDetail', parse: ->(search_term, *values) {@metrics.keys.zip(values.map{|v| {search_term => v}}).to_h} }
        hash[:referrer] = {name: 'insightTrafficSourceDetail', parse: ->(url, *values) {@metrics.keys.zip(values.map{|v| {url => v}}).to_h} }
        hash[:video] = {name: 'video', parse: ->(video_id, *values) { @metrics.keys.zip(values.map{|v| {video_id => v}}).to_h} }
        hash[:playlist] = {name: 'playlist', parse: ->(playlist_id, *values) { @metrics.keys.zip(values.map{|v| {playlist_id => v}}).to_h} }
        hash[:device_type] = {name: 'deviceType', parse: ->(type, *values) {@metrics.keys.zip(values.map{|v| {type.downcase.to_sym => v}}).to_h} }
        hash[:country] = {name: 'country', parse: ->(country_code, *values) { @metrics.keys.zip(values.map{|v| {country_code => v}}).to_h} }
        hash[:state] = {name: 'province', parse: ->(country_and_state_code, *values) { @metrics.keys.zip(values.map{|v| {country_and_state_code[3..-1] => v}}).to_h} }
        hash[:gender_age_group] = {name: 'gender,ageGroup', parse: ->(gender, *values) { [gender.downcase.to_sym, *values] }}
        hash[:gender] = {name: 'gender', parse: ->(gender, *values) {@metrics.keys.zip(values.map{|v| {gender.downcase.to_sym => v}}).to_h} }
        hash[:age_group] = {name: 'ageGroup', parse: ->(age_group, *values) {@metrics.keys.zip(values.map{|v| {age_group[3..-1] => v}}).to_h} }
      end

      # @see https://developers.google.com/youtube/analytics/v1/dimsmets/dims#Traffic_Source_Dimensions
      # @note EXT_APP is also returned but it’s not in the documentation above!
      TRAFFIC_SOURCES = {
        advertising: 'ADVERTISING',
        annotation: 'ANNOTATION',
        external_app: 'EXT_APP',
        external_url: 'EXT_URL',
        embedded: 'NO_LINK_EMBEDDED',
        other: 'NO_LINK_OTHER',
        playlist: 'PLAYLIST',
        promoted: 'PROMOTED',
        related_video: 'RELATED_VIDEO',
        subscriber: 'SUBSCRIBER',
        channel: 'YT_CHANNEL',
        other_page: 'YT_OTHER_PAGE',
        search: 'YT_SEARCH',
        google: 'GOOGLE_SEARCH',
        notification: 'NOTIFICATION',
        info_card: 'INFO_CARD'
      }

      # @see https://developers.google.com/youtube/analytics/v1/dimsmets/dims#Playback_Location_Dimensions
      PLAYBACK_LOCATIONS = {
        channel: 'CHANNEL',
        watch: 'WATCH',
        embedded: 'EMBEDDED',
        other: 'YT_OTHER',
        external_app: 'EXTERNAL_APP',
        mobile: 'MOBILE' # only present for data < September 10, 2013
      }

      attr_writer :metrics

      def within(days_range, country, state, dimension, try_again = true)
        @days_range = days_range
        @dimension = dimension
        @country = country
        @state = state
        if dimension == :gender_age_group # array of array
          Hash.new{|h,k| h[k] = Hash.new 0.0}.tap do |hash|
            each{|gender, age_group, value| hash[gender][age_group[3..-1]] = value}
          end
        else
          hash = flat_map do |hashes|
            hashes.map do |metric, values|
              [metric, values.transform_values{|v| type_cast(v, @metrics[metric])}]
            end.to_h
          end
          hash = hash.inject(@metrics.transform_values{|v| {}}) do |result, hash|
            result.deep_merge hash
          end
          if dimension == :month
            hash = hash.transform_values{|h| h.sort_by{|range, v| range.first}.to_h}
          elsif dimension.in? [:traffic_source, :country, :state, :playback_location]
            hash = hash.transform_values{|h| h.sort_by{|range, v| -v}.to_h}
          end
          (@metrics.one? || @metrics.keys == [:earnings, :estimated_minutes_watched]) ? hash[@metrics.keys.first] : hash
        end
      # NOTE: Once in a while, YouTube responds with 400 Error and the message
      # "Invalid query. Query did not conform to the expectations."; in this
      # case running the same query after one second fixes the issue. This is
      # not documented by YouTube and hardly testable, but trying again the
      # same query is a workaround that works and can hardly cause any damage.
      # Similarly, once in while YouTube responds with a random 503 error.
      rescue Yt::Error => e
        try_again && rescue?(e) ? sleep(3) && within(days_range, country, state, dimension, false) : raise
      end

    private

      def type_cast(value, type)
        case [type]
          when [Integer] then value.to_i if value
          when [Float] then value.to_f if value
        end
      end

      def new_item(data)
        instance_exec *data, &DIMENSIONS[@dimension][:parse]
      end

      # @see https://developers.google.com/youtube/analytics/v1/content_owner_reports
      def list_params
        super.tap do |params|
          params[:path] = '/youtube/analytics/v1/reports'
          params[:params] = reports_params
          params[:camelize_params] = false
        end
      end

      def reports_params
        @parent.reports_params.tap do |params|
          params['start-date'] = @days_range.begin
          params['end-date'] = @days_range.end
          params['metrics'] = @metrics.keys.join(',').to_s.camelize(:lower)
          params['dimensions'] = DIMENSIONS[@dimension][:name] unless @dimension == :range
          params['max-results'] = 10 if @dimension == :video
          params['max-results'] = 200 if @dimension == :playlist
          params['max-results'] = 25 if @dimension.in? [:embedded_player_location, :related_video, :search_term, :referrer]
          params['sort'] = "-#{@metrics.keys.join(',').to_s.camelize(:lower)}" if @dimension.in? [:video, :playlist, :embedded_player_location, :related_video, :search_term, :referrer]
          params[:filters] = ((params[:filters] || '').split(';') + ["country==US"]).compact.uniq.join(';') if @dimension == :state && !@state
          params[:filters] = ((params[:filters] || '').split(';') + ["country==#{@country}"]).compact.uniq.join(';') if @country && !@state
          params[:filters] = ((params[:filters] || '').split(';') + ["province==US-#{@state}"]).compact.uniq.join(';') if @state
          params[:filters] = ((params[:filters] || '').split(';') + ['isCurated==1']).compact.uniq.join(';') if @dimension == :playlist
          params[:filters] = ((params[:filters] || '').split(';') + ['insightPlaybackLocationType==EMBEDDED']).compact.uniq.join(';') if @dimension == :embedded_player_location
          params[:filters] = ((params[:filters] || '').split(';') + ['insightTrafficSourceType==RELATED_VIDEO']).compact.uniq.join(';') if @dimension == :related_video
          params[:filters] = ((params[:filters] || '').split(';') + ['insightTrafficSourceType==YT_SEARCH']).compact.uniq.join(';') if @dimension == :search_term
          params[:filters] = ((params[:filters] || '').split(';') + ['insightTrafficSourceType==EXT_URL']).compact.uniq.join(';') if @dimension == :referrer
        end
      end

      def items_key
        'rows'
      end

      def rescue?(error)
        'badRequest'.in?(error.reasons) && error.to_s =~ /did not conform/
      end
    end
  end
end
