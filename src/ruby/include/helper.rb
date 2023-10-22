require "neo4j_bolt"
require "sinatra/base"

class Main < Sinatra::Base
    include Neo4jBolt
    
    def assert(condition, message = "assertion failed", suppress_backtrace = false, delay = nil)
        unless condition
            debug_error message
            e = StandardError.new(message)
            e.set_backtrace([]) if suppress_backtrace
            sleep delay unless delay.nil?
            raise e
        end
    end

    def assert_with_delay(condition, message = "assertion failed", suppress_backtrace = false)
        assert(condition, message, suppress_backtrace, 3.0)
    end

    def test_request_parameter(data, key, options)
        type = ((options[:types] || {})[key]) || String
        assert(data[key.to_s].is_a?(type), "#{key.to_s} is a #{type} (it's a #{data[key.to_s].class})")
        if type == String
            assert(data[key.to_s].size <= (options[:max_value_lengths][key] || options[:max_string_length]), "too_much_data")
        end
    end

    def parse_request_data(options = {})
        options[:max_body_length] ||= 512
        options[:max_string_length] ||= 512
        options[:required_keys] ||= []
        options[:optional_keys] ||= []
        options[:max_value_lengths] ||= {}
        data_str = request.body.read(options[:max_body_length]).to_s
        @latest_request_body = data_str.dup
        begin
            assert(data_str.is_a? String)
            assert(data_str.size < options[:max_body_length], "too_much_data")
            data = JSON::parse(data_str)
            @latest_request_body_parsed = data.dup
            result = {}
            options[:required_keys].each do |key|
                assert(data.include?(key.to_s), "missing key: #{key}")
                test_request_parameter(data, key, options)
                result[key.to_sym] = data[key.to_s]
            end
            options[:optional_keys].each do |key|
                if data.include?(key.to_s)
                    test_request_parameter(data, key, options)
                    result[key.to_sym] = data[key.to_s]
                end
            end
            result
        rescue
            debug "Request was:"
            debug data_str
            raise
        end
    end

    before "*" do
        @latest_request_body = nil
        @latest_request_body_parsed = nil
    end

    after "*" do
        if response.status.to_i == 200
            if @respond_content
                response.body = @respond_content
                response.headers["Content-Type"] = @respond_mimetype
                if @respond_filename
                    response.headers["Content-Disposition"] = "attachment; filename=\"#{@respond_filename}\""
                end
            else
                @respond_hash ||= {}
                response.body = @respond_hash.to_json
            end
        end
    end

    after '*' do
        if NEED_NEO4J
            cleanup_neo4j()
        end
    end

    def respond(hash = {})
        @respond_hash = hash
    end

    def respond_raw_with_mimetype(content, mimetype)
        @respond_content = content
        @respond_mimetype = mimetype
    end

    def respond_raw_with_mimetype_and_filename(content, mimetype, filename)
        @respond_content = content
        @respond_mimetype = mimetype
        @respond_filename = filename
    end

    def respond_with_file(path, &block)
        unless File.exist?(path)
            status 404
            return
        end
        mime_type = 'text/plain'
        mime_type = 'text/html' if path =~ /\.html$/
        mime_type = 'image/jpeg' if path =~ /\.jpe?g$/
        mime_type = 'image/png' if path =~ /\.png$/
        mime_type = 'image/gif' if path =~ /\.gif$/
        mime_type = 'image/svg' if path =~ /\.svg$/
        mime_type = 'application/pdf' if path =~ /\.pdf$/
        mime_type = 'text/css' if path =~ /\.css$/
        mime_type = 'text/javascript' if path =~ /\.js$/
        mime_type = 'text/json' if path =~ /\.json$/
        content = File.read(path)
        if block_given?
            content = yield(content, mime_type)
        end
        respond_raw_with_mimetype(content, mime_type)
    end
end
