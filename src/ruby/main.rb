require './include/helper.rb'
require 'base64'
require 'cgi'
require 'digest'
require 'kramdown'
require 'mail'
require 'neo4j_bolt'
require './credentials.rb'
require 'securerandom'
require 'sinatra/base'
require 'sinatra/cookies'

Neo4jBolt.bolt_host = 'neo4j'
Neo4jBolt.bolt_port = 7687

class Neo4jGlobal
    include Neo4jBolt
end

$neo4j = Neo4jGlobal.new

def assert(condition, message = 'assertion failed')
    raise message unless condition
end

def debug(message, index = 0)
    index = 0
    begin
        while index < caller_locations.size - 1 && ['transaction', 'neo4j_query', 'neo4j_query_expect_one'].include?(caller_locations[index].base_label)
            index += 1
        end
    rescue
        index = 0
    end
    # STDERR.puts caller_locations.to_yaml
    l = caller_locations[index]
    ls = ''
    begin
        ls = "#{l.path.sub('/app/', '')}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub('/app/', '')}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime('%H:%M:%S')} [#{ls}] #{message}"
end

def debug_error(message)
    l = caller_locations.first
    ls = ""
    begin
        ls = "#{l.path.sub("/app/", "")}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub("/app/", "")}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime("%H:%M:%S")} [ERROR] [#{ls}] #{message}"
end

class RandomTag
    BASE_31_ALPHABET = '0123456789bcdfghjklmnpqrstvwxyz'
    def self.to_base31(i)
        result = ''
        while i > 0
            result += BASE_31_ALPHABET[i % 31]
            i /= 31
        end
        result
    end

    def self.generate(length = 12)
        self.to_base31(SecureRandom.hex(length).to_i(16))[0, length]
    end
end

def mail_html_to_plain_text(s)
    s.gsub('<p>', "\n\n").gsub(/<br\s*\/?>/, "\n").gsub(/<\/?[^>]*>/, '').strip
end

def deliver_mail(plain_text = nil, &block)
    mail = Mail.new do
        charset = 'UTF-8'
        message = self.instance_eval(&block)
        if plain_text.nil?
            html_part do
                content_type 'text/html; charset=UTF-8'
                body message
            end

            text_part do
                content_type 'text/plain; charset=UTF-8'
                body mail_html_to_plain_text(message)
            end
        else
            text_part do
                content_type 'text/plain; charset=UTF-8'
                body plain_text
            end
        end
    end
    if DEVELOPMENT
        STDERR.puts "Not sending mail in development mode!"
        STDERR.puts '-' * 40
        STDERR.puts "From:    #{mail.from.join('; ')}"
        STDERR.puts "To:      #{mail.to.join('; ')}"
        STDERR.puts "Subject: #{mail.subject}"
        STDERR.puts mail.text_part
        STDERR.puts '-' * 40
    else
        mail.deliver!
    end
end

class SetupDatabase
    include Neo4jBolt

    def setup(main)
    #     delay = 1
    #     10.times do
    #         begin
    #             neo4j_query("MATCH (n) RETURN n LIMIT 1;")
    #             break
    #         rescue
    #             debug $!
    #             debug "Retrying setup after #{delay} seconds..."
    #             sleep delay
    #             delay += 1
    #         end
    #     end
    end
end

class Main < Sinatra::Base
    include Neo4jBolt
    helpers Sinatra::Cookies

    configure do
        CONSTRAINTS_LIST = [
            'User/email',
            'Session/sid',
        ]

        INDEX_LIST = [
            # 'Flag/index'
        ]

        setup = SetupDatabase.new()
        setup.setup(self)
        # setup.wait_for_neo4j()
        $neo4j.setup_constraints_and_indexes(CONSTRAINTS_LIST, INDEX_LIST)
        debug "Server is up and running!"

        # create admin users in database if they don't exist yet
        ADMIN_USERS.each do |email|
            $neo4j.neo4j_query(<<~END_OF_QUERY, {:email => email})
                MERGE (u:User {email: $email});
            END_OF_QUERY
        end
    end

    before '*' do
        @session_user = nil
        if request.cookies.include?('sid')
            sid = request.cookies['sid']
            if (sid.is_a? String) && (sid =~ /^[0-9A-Za-z]+$/)
                first_sid = sid.split(',').first
                if first_sid =~ /^[0-9A-Za-z]+$/
                    results = neo4j_query(<<~END_OF_QUERY, :sid => first_sid).to_a
                        MATCH (s:Session {sid: $sid})-[:FOR]->(u:User)
                        RETURN s, u;
                    END_OF_QUERY
                    if results.size == 1
                        begin
                            session = results.first['s']
                            session_expiry = session[:expires]
                            if DateTime.parse(session_expiry) > DateTime.now
                                email = results.first['u'][:email]
                                @session_user = {
                                    :email => email.downcase,
                                    :name => results.first['u'][:name],
                                    :alias => results.first['u'][:alias],
                                    :affiliation => results.first['u'][:affiliation],
                                    :grade => results.first['u'][:grade],
                                    :want_mails => results.first['u'][:want_mails].nil? ? true : results.first['u'][:want_mails],
                                    :consent_real_name => results.first['u'][:consent_real_name],
                                    :will_show_up => results.first['u'][:will_show_up] || 'no',
                                    :photo_sha1 => results.first['u'][:photo_sha1],
                                    :photo_mime_type => results.first['u'][:photo_mime_type],
                                }
                            end
                        rescue
                            # something went wrong, delete the session
                            results = neo4j_query(<<~END_OF_QUERY, :sid => first_sid).to_a
                                MATCH (s:Session {sid: $sid})
                                DETACH DELETE s;
                            END_OF_QUERY
                        end
                    end
                end
            end
        end
    end

    def this_is_a_page_for_logged_in_users!
        assert(!@session_user.nil?)
    end

    def user_logged_in?
        return (!@session_user.nil?)
    end

    post '/api/request_login' do
        data = parse_request_data(:required_keys => [:email])
        email = data[:email].downcase

        tag = RandomTag::generate(12)
        srand(Digest::SHA2.hexdigest(LOGIN_CODE_SALT).to_i + (Time.now.to_f * 1000000).to_i)
        random_code = (0..5).map { |x| rand(10).to_s }.join('')
        random_code = '123456' if DEVELOPMENT

        neo4j_query_expect_one(<<~END_OF_QUERY, {:email => email})
            MATCH (u:User {email: $email})
            RETURN u.email;
        END_OF_QUERY

        neo4j_query_expect_one(<<~END_OF_QUERY, {:email => email, :tag => tag, :code => random_code})
            MATCH (u:User {email: $email})
            CREATE (r:LoginRequest)-[:FOR]->(u)
            SET r.tag = $tag
            SET r.code = $code
            RETURN u.email;
        END_OF_QUERY

        deliver_mail do
            to data[:email]
            # bcc SMTP_FROM
            from SMTP_FROM

            subject "Dein Anmeldecode lautet #{random_code}"

            StringIO.open do |io|
                io.puts "<p>Hallo!</p>"
                io.puts "<p>Dein Anmeldecode lautet:</p>"
                io.puts "<p style='font-size: 200%;'>#{random_code}</p>"
                io.puts "<p>Der Code ist für zehn Minuten gültig. Nachdem du dich angemeldet hast, bleibst du für ein ganzes Jahr angemeldet (falls du dich nicht wieder abmeldest).</p>"
                io.puts "<p>Falls du diese E-Mail nicht angefordert hast, hat jemand versucht, sich mit deiner E-Mail-Adresse auf <a href='https://#{WEBSITE_HOST}/'>https://#{WEBSITE_HOST}/</a> anzumelden. In diesem Fall musst du nichts weiter tun (es sei denn, du befürchtest, dass jemand anderes Zugriff auf dein E-Mail-Konto hat – dann solltest du dein E-Mail-Passwort ändern).</p>"
                io.string
            end
        end
        respond(:ok => 'yay', :tag => tag)
    end

    def logout()
        sid = request.cookies['sid']
        if sid =~ /^[0-9A-Za-z,]+$/
            current_sid = sid.split(',').first
            if current_sid =~ /^[0-9A-Za-z]+$/
                result = neo4j_query(<<~END_OF_QUERY, :sid => current_sid)
                    MATCH (s:Session {sid: $sid})
                    DETACH DELETE s;
                END_OF_QUERY
            end
        end
    end

    post '/api/logout' do
        logout()
        respond(:ok => 'yeah')
    end

    def load_rezept(tag)
        assert(!tag.include?('..'))
        data = File.read("/src/ruby/rezepte/#{tag}.md")
        html = Kramdown::Document.new(data).to_html
        {:content => data, :html => html}
    end

    def list_rezepte()
        StringIO.open do |io|
            tags = []
            heading_for_tag = {}
            Dir['/src/ruby/rezepte/*.md'].each do |path|
                tag = File.basename(path).sub('.md', '')
                heading = File.read("/src/ruby/rezepte/#{tag}.md").strip.split("\n").first.gsub('#', '').strip
                heading_for_tag[tag] = heading
                tags << tag
            end
            tags.sort do |a, b|
                heading_for_tag[a].downcase <=> heading_for_tag[b].downcase
            end.each do |tag|
                io.puts "<div><a href='/rezept?#{tag}'>#{heading_for_tag[tag]}</a></div>"
            end
            io.string
        end
    end

    post '/api/load_rezept' do
        data = parse_request_data(:required_keys => [:tag])
        respond(:data => load_rezept(data[:tag]))
    end

    get '/*' do
        path = request.path
        if path == '/'
            path = '/index.html'
        end
        confirm_tag = nil
        confirm_message = nil
        if path[0, 3] == '/l/'
            rest = path[3, path.size - 3].split('/')
            path = '/index.html'
            tag = rest[0]
            code = rest[1]
            begin
                email = neo4j_query_expect_one(<<~END_OF_QUERY, {:tag => tag, :code => code})['email']
                    MATCH (r:LoginRequest {tag: $tag, code: $code})-[:FOR]->(u:User)
                    RETURN u.email AS email;
                END_OF_QUERY
                neo4j_query(<<~END_OF_QUERY, {:tag => tag, :code => code})
                    MATCH (r:LoginRequest {tag: $tag, code: $code})-[:FOR]->(u:User)
                    DETACH DELETE r;
                END_OF_QUERY
                sid = RandomTag::generate(24)
                neo4j_query_expect_one(<<~END_OF_QUERY, {:sid => sid, :email => email, :expires => (DateTime.now() + 365).to_s})
                    MATCH (u:User {email: $email})
                    WITH u
                    CREATE (s:Session {sid: $sid, expires: $expires})-[:FOR]->(u)
                    RETURN s.sid AS sid;
                END_OF_QUERY
                response.set_cookie('sid',
                    :value => sid,
                    :expires => Time.new + 3600 * 24 * 365,
                    :path => '/',
                    :httponly => true,
                    :secure => DEVELOPMENT ? false : true)
            # rescue StandardError => e
                # debug e
            end
            redirect "#{WEB_ROOT}/", 302
        end
        path = path + '.html' unless path.include?('.')
        respond_with_file(File.join('/src/static', path)) do |content, mime_type|
            if mime_type == 'text/html'
                template = File.read(File.join('/src/static', '_template.html'))
                template.sub!('#{CONTENT}', content)
                s = template
                while true
                    index = s.index('#{')
                    break if index.nil?
                    length = 2
                    balance = 1
                    while index + length < s.size && balance > 0
                        c = s[index + length]
                        balance -= 1 if c == '}'
                        balance += 1 if c == '{'
                        length += 1
                    end
                    code = s[index + 2, length - 3]
                    begin
                        s[index, length] = eval(code).to_s || ''
                    rescue
                        STDERR.puts "Error while evaluating:"
                        STDERR.puts code
                        raise
                    end
                end
                s
            end
        end
    end
end
