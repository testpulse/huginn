module LiquidInterpolatable
  extend ActiveSupport::Concern

  included do
    validate :validate_interpolation
  end

  def valid?(context = nil)
    super
  rescue Liquid::Error
    errors.empty?
  end

  def validate_interpolation
    interpolated
  rescue Liquid::Error => e
    errors.add(:options, "has an error with Liquid templating: #{e.message}")
  rescue
    # Calling `interpolated` without an incoming may naturally fail
    # with various errors when an agent expects one.
  end

  # Return the current interpolation context.  Use this in your Agent
  # class to manipulate interpolation context for user.
  #
  # For example, to provide local variables:
  #
  #     # Create a new scope to define variables in:
  #     interpolation_context.stack {
  #       interpolation_context['_something_'] = 42
  #       # And user can say "{{_something_}}" in their options.
  #       value = interpolated['some_key']
  #     }
  #
  def interpolation_context
    @interpolation_context ||= Context.new(self)
  end

  # Take the given object as "self" in the current interpolation
  # context while running a given block.
  #
  # The most typical use case for this is to evaluate options for each
  # received event like this:
  #
  #     def receive(incoming_events)
  #       incoming_events.each do |event|
  #         interpolate_with(event) do
  #           # Handle each event based on "interpolated" options.
  #         end
  #       end
  #     end
  def interpolate_with(self_object)
    case self_object
    when nil
      yield
    else
      context = interpolation_context
      begin
        context.environments.unshift(self_object.to_liquid)
        yield
      ensure
        context.environments.shift
      end
    end
  end

  def interpolate_options(options, self_object = nil)
    interpolate_with(self_object) do
      case options
      when String
        interpolate_string(options)
      when ActiveSupport::HashWithIndifferentAccess, Hash
        options.each_with_object(ActiveSupport::HashWithIndifferentAccess.new) { |(key, value), memo|
          memo[key] = interpolate_options(value)
        }
      when Array
        options.map { |value| interpolate_options(value) }
      else
        options
      end
    end
  end

  def interpolated(self_object = nil)
    interpolate_with(self_object) do
      (@interpolated_cache ||= {})[[options, interpolation_context]] ||=
        interpolate_options(options)
    end
  end

  def interpolate_string(string, self_object = nil)
    interpolate_with(self_object) do
      Liquid::Template.parse(string).render!(interpolation_context)
    end
  end

  class Context < Liquid::Context
    def initialize(agent)
      super({}, {}, { agent: agent }, true)
    end

    def hash
      [@environments, @scopes, @registers].hash
    end

    def eql?(other)
      other.environments == @environments &&
        other.scopes == @scopes &&
        other.registers == @registers
    end
  end

  require 'uri'
  module Filters
    # Percent encoding for URI conforming to RFC 3986.
    # Ref: http://tools.ietf.org/html/rfc3986#page-12
    def uri_escape(string)
      CGI.escape(string) rescue string
    end

    # Parse an input into a URI object, optionally resolving it
    # against a base URI if given.
    #
    # A URI object will have the following properties: scheme,
    # userinfo, host, port, registry, path, opaque, query, and
    # fragment.
    def to_uri(uri, base_uri = nil)
      if base_uri
        URI(base_uri) + uri.to_s
      else
        URI(uri.to_s)
      end
    rescue URI::Error
      nil
    end

    # Get the destination URL of a given URL by recursively following
    # redirects, up to 5 times in a row.  If a given string is not a
    # valid absolute HTTP URL or in case of too many redirects, the
    # original string is returned.  If any network/protocol error
    # occurs while following redirects, the last URL followed is
    # returned.
    def uri_expand(url, limit = 5)
      case url
      when URI
        uri = url
      else
        url = url.to_s
        begin
          uri = URI(url)
        rescue URI::Error
          return url
        end
      end

      http = Faraday.new do |builder|
        builder.adapter :net_http
        # builder.use FaradayMiddleware::FollowRedirects, limit: limit
        # ...does not handle non-HTTP URLs.
      end

      limit.times do
        begin
          case uri
          when URI::HTTP
            return uri.to_s unless uri.host
            response = http.head(uri)
            case response.status
            when 301, 302, 303, 307
              if location = response['location']
                uri += location
                next
              end
            end
          end
        rescue URI::Error, Faraday::Error, SystemCallError => e
          logger.error "#{e.class} in #{__method__}(#{url.inspect}) [uri=#{uri.to_s.inspect}]: #{e.message}:\n#{e.backtrace.join("\n")}"
        end

        return uri.to_s
      end

      logger.error "Too many rediretions in #{__method__}(#{url.inspect}) [uri=#{uri.to_s.inspect}]"

      url
    end

    # Escape a string for use in XPath expression
    def to_xpath(string)
      subs = string.to_s.scan(/\G(?:\A\z|[^"]+|[^']+)/).map { |x|
        case x
        when /"/
          %Q{'#{x}'}
        else
          %Q{"#{x}"}
        end
      }
      if subs.size == 1
        subs.first
      else
        'concat(' << subs.join(', ') << ')'
      end
    end
    
    def regex_replace(input, regex, replacement = ''.freeze)
      input.to_s.gsub(Regexp.new(regex), replacement.to_s)
    end
    
    def regex_replace_first(input, regex, replacement = ''.freeze)
      input.to_s.sub(Regexp.new(regex), replacement.to_s)
    end
    
    private

    def logger
      @@logger ||=
        if defined?(Rails)
          Rails.logger
        else
          require 'logger'
          Logger.new(STDERR)
        end
    end
  end
  Liquid::Template.register_filter(LiquidInterpolatable::Filters)

  module Tags
    class Credential < Liquid::Tag
      def initialize(tag_name, name, tokens)
        super
        @credential_name = name.strip
      end

      def render(context)
        credential = context.registers[:agent].credential(@credential_name)
        raise "No user credential named '#{@credential_name}' defined" if credential.nil?
        credential
      end
    end

    class LineBreak < Liquid::Tag
      def render(context)
        "\n"
      end
    end
  end
  Liquid::Template.register_tag('credential', LiquidInterpolatable::Tags::Credential)
  Liquid::Template.register_tag('line_break', LiquidInterpolatable::Tags::LineBreak)
end
