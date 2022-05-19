require 'faraday'
require 'faraday_middleware'
require 'active_support'
require 'active_support/core_ext'
require 'active_support/time_with_zone'

module PagerDuty

  class Connection
    attr_accessor :connection

    API_VERSION = 2
    API_PREFIX = "https://api.pagerduty.com/"

    class FileNotFoundError < RuntimeError
    end

    class ApiError < RuntimeError
    end

    class RateLimitError < RuntimeError
    end

    class RaiseFileNotFoundOn404 < Faraday::Middleware
      def call(env)
        response = @app.call env
        if response.status == 404
          raise FileNotFoundError, response.env[:url].to_s
        else
          response
        end
      end
    end

    class RaiseApiErrorOnNon200 < Faraday::Middleware
      def call(env)
        response = @app.call env
        unless [200, 201, 204].include?(response.status)
          url = response.env[:url].to_s
          message = "Got HTTP #{response.status}: #{response.reason_phrase}\nFrom #{url}"

          if error = response.body
            # TODO May Need to check error.errors too
            message += "\n#{JSON.parse(error)}"
          end

          raise ApiError, message
        else
          response
        end
      end
    end

    class RaiseRateLimitOn429 < Faraday::Middleware
      def call(env)
        response = @app.call env
        if response.status == 429
          raise RateLimitError, response.env[:url].to_s
        end

        response
      end
    end

    class ConvertTimesParametersToISO8601 < Faraday::Middleware
      TIME_KEYS = [:since, :until]
      def call(env)

        body = env[:body]
        TIME_KEYS.each do |key|
          if body.has_key?(key)
            body[key] = body[key].iso8601 if body[key].respond_to?(:iso8601)
          end
        end

        @app.call env
      end
    end

    class ParseTimeStrings < Faraday::Response::Middleware
      TIME_KEYS = %w(
        at
        created_at
        created_on
        end
        end_time
        last_incident_timestamp
        last_status_change_on
        start
        started_at
        start_time
      )

      OBJECT_KEYS = %w(
        alert
        entry
        incident
        log_entry
        maintenance_window
        note
        override
        service
      )

      NESTED_COLLECTION_KEYS = %w(
        acknowledgers
        assigned_to
        pending_actions
      )

      def parse(body)
        case body
        when Hash, ::Hashie::Mash
          OBJECT_KEYS.each do |key|
            object = body[key]
            parse_object_times(object) if object

            collection_key = key.pluralize
            collection = body[collection_key]
            parse_collection_times(collection) if collection
          end

          body
        when Array
          body.map! { |element| parse(element) }
        else
          raise "Can't parse times of #{body.class}: #{body}"
        end
      end

      def parse_collection_times(collection)
        collection.each do |object|
          parse_object_times(object)

          NESTED_COLLECTION_KEYS.each do |key|
            object_collection = object[key]
            parse_collection_times(object_collection) if object_collection
          end
        end
      end

      def parse_object_times(object)
        time = Time.zone ? Time.zone : Time

        TIME_KEYS.each do |key|
          if object.has_key?(key) && object[key].present?
            object[key] = time.parse(object[key])
          end
        end
      end
    end

    def initialize(token, token_type: :Token, url: API_PREFIX, debug: false)
      @connection = Faraday.new do |conn|
        conn.url_prefix = url

        token_arg =
          case token_type
          when :Token then { token: token }
          when :Bearer then token
          else raise ArgumentError, "invalid token_type: #{token_type.inspect}"
          end
        conn.request :authorization, token_type, token_arg

        conn.use ConvertTimesParametersToISO8601

        # use json
        conn.request :json
        conn.headers[:accept] = "application/vnd.pagerduty+json;version=#{API_VERSION}"

        # json back, mashify it
        conn.use ParseTimeStrings
        conn.response :mashify
        conn.response :json
        conn.response :logger, ::Logger.new(STDOUT), bodies: true if debug

        # Because Faraday::Middleware executes in reverse order of
        # calls to conn.use, status code error handling goes at the
        # end of the block so that it runs first
        conn.use RaiseApiErrorOnNon200
        conn.use RaiseFileNotFoundOn404
        conn.use RaiseRateLimitOn429

        conn.adapter  Faraday.default_adapter
      end
    end

    def get(path, request = {})
      # paginate anything being 'get'ed, because the offset/limit isn't intuitive
      request[:query_params] = {} if !request[:query_params]
      page = request[:query_params].fetch(:page, 1).to_i
      limit = request[:query_params].fetch(:limit, 100).to_i
      offset = (page - 1) * limit

      query_params = request[:query_params].merge(offset: offset, limit: limit)

      run_request(:get, path, **request.merge(query_params: query_params))
    end

    def put(path, request = {})
      run_request(:put, path, **request)
    end

    def post(path, request = {})
      run_request(:post, path, **request)
    end

    def delete(path, request = {})
      run_request(:delete, path, **request)
    end

    private

    def run_request(method, path, body: {}, headers: {}, query_params: {})
      path = path.gsub(/^\//, '') # strip leading slash, to make sure relative things happen on the connection

      connection.params = query_params
      response = connection.run_request(method, path, body, headers)
      response.body
    end
  end
end
