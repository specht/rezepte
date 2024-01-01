#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require 'yaml'
require './env.template.rb'
warn_level = $VERBOSE
$VERBOSE = nil
require './env.rb' if File.exist?('env.rb')
$VERBOSE = warn_level

PROFILE = [:static, :dynamic]

STAGING = File::dirname(File::expand_path(__FILE__)).include?('staging')
PROJECT_NAME_FIXED = PROJECT_NAME + (STAGING ? 'staging' : '') + (DEVELOPMENT ? 'dev' : '')
DEV_NGINX_PORT = 8025
DEV_NEO4J_PORT = 8021
RAW_PATH = File.join(DATA_PATH, 'raw')
GEN_PATH = File.join(DATA_PATH, 'gen')
NEO4J_LOGS_PATH = File::join(LOGS_PATH, 'neo4j')
NEO4J_DATA_PATH = File::join(DATA_PATH, 'neo4j')
INTERNAL_FILES_PATH = File::join(DATA_PATH, 'internal')

docker_compose = {
    :services => {},
}

if PROFILE.include?(:static)
    docker_compose[:services][:nginx] = {
        :build => './docker/nginx',
        :volumes => [
            './src/static:/usr/share/nginx/html:ro',
            "#{LOGS_PATH}:/var/log/nginx",
        ]
    }
    if !DEVELOPMENT
        docker_compose[:services][:nginx][:environment] = [
            'VIRTUAL_HOST=physikmarathon.de',
            'LETSENCRYPT_HOST=physikmarathon.de',
            'LETSENCRYPT_EMAIL=specht@gymnasiumsteglitz.de'
        ]
        docker_compose[:services][:nginx][:expose] = ['80']
    end
    docker_compose[:services][:nginx][:links] = ["ruby:#{PROJECT_NAME_FIXED}_ruby_1"]
    nginx_config = <<~eos
        log_format custom '$http_x_forwarded_for - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$request_time"';

        map $sent_http_content_type $expires {
            default                         off;
            text/html                       epoch;
            text/css                        max;
            application/javascript          max;
            ~image/                         max;
            ~font/                          max;
            application/x-font-ttf          max;
            application/x-font-otf          max;
            application/font-woff           max;
            application/font-woff2          max;
        }

        server {
            #pagespeed on;
            #pagespeed FileCachePath              "/var/cache/pagespeed/";
            #pagespeed FileCacheSizeKb            102400;
            #pagespeed FileCacheCleanIntervalMs   3600000;
            #pagespeed FileCacheInodeLimit        500000;
            #pagespeed EnableFilters prioritize_critical_css;
            #pagespeed DisableFilters rewrite_images;

            listen 80;
            server_name localhost;
            client_max_body_size 100M;
            expires $expires;

            gzip on;
            gzip_comp_level 6;
            gzip_min_length 256;
            gzip_buffers 16 8k;
            gzip_proxied any;
            gzip_types
                text/plain
                text/css
                text/js
                text/xml
                text/javascript
                application/javascript
                application/x-javascript
                application/json
                application/xml
                application/rss+xml
                image/svg+xml;

            access_log /var/log/nginx/access.log custom;

            charset utf-8;

            location / {
                root /usr/share/nginx/html;
                include /etc/nginx/mime.types;
                try_files $uri @ruby;
            }

            location @ruby {
                proxy_pass http://#{PROJECT_NAME_FIXED}_ruby_1:9292;
                proxy_set_header Host $host;
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection Upgrade;
            }
        }
    eos
    File::open('docker/nginx/default.conf', 'w') do |f|
        f.write nginx_config
    end
    if PROFILE.include?(:dynamic)
        docker_compose[:services][:nginx][:depends_on] = [:ruby]
    end
end

if PROFILE.include?(:dynamic)
    env = []
    env << 'DEVELOPMENT=1' if DEVELOPMENT
    env << 'STAGING=1' if STAGING
    env << "WEBSITE_HOST=#{WEBSITE_HOST}"
    docker_compose[:services][:ruby] = {
        :build => './docker/ruby',
        :volumes => ['./src:/src:ro',
                     "#{RAW_PATH}:/raw",
                     "#{GEN_PATH}:/gen",
                    ],
        :environment => env,
        :working_dir => '/src/ruby',
        :entrypoint =>  DEVELOPMENT ?
            'rerun -b --dir /src/ruby -s SIGKILL \'rackup --host 0.0.0.0\'' :
            'rackup --host 0.0.0.0'
    }
    if PROFILE.include?(:neo4j)
        docker_compose[:services][:ruby][:depends_on] ||= []
        docker_compose[:services][:ruby][:depends_on] << :neo4j
        # docker_compose[:services][:ruby][:links] = ['neo4j:neo4j']
    end
end

if PROFILE.include?(:neo4j)
    docker_compose[:services][:neo4j] = {
        :build => './docker/neo4j',
        :volumes => ["#{NEO4J_DATA_PATH}:/data",
                     "#{NEO4J_LOGS_PATH}:/logs"]
    }
    docker_compose[:services][:neo4j][:environment] = [
        'NEO4J_AUTH=none',
        'NEO4J_dbms_logs__timezone=SYSTEM',
        'NEO4J_dbms_allow__upgrade=true',
    ]
    docker_compose[:services][:neo4j][:user] = '1000'
end

if DEVELOPMENT
    docker_compose[:services][:nginx][:ports] = ["0.0.0.0:#{DEV_NGINX_PORT}:80"]
    if PROFILE.include?(:neo4j)
        docker_compose[:services][:neo4j][:ports] ||= []
        docker_compose[:services][:neo4j][:ports] << "127.0.0.1:#{DEV_NEO4J_PORT}:7474"
        docker_compose[:services][:neo4j][:ports] << "127.0.0.1:7687:7687"
    end
end

unless DEVELOPMENT
    docker_compose[:services].values.each do |x|
        x[:restart] = :always
    end
end

docker_compose[:networks] = {DOCKER_NETWORK_NAME => {}}
docker_compose[:services].each_pair do |k, v|
    v[:networks] = {DOCKER_NETWORK_NAME => {:aliases => [k]}}
end


File::open('docker-compose.yaml', 'w') do |f|
    f.puts "# NOTICE: don't edit this file directly, use config.rb instead!\n"
    f.write(JSON::parse(docker_compose.to_json).to_yaml)
end

FileUtils::mkpath(LOGS_PATH)
FileUtils::mkpath(File.join(LOGS_PATH, 'neo4j'))
if PROFILE.include?(:dynamic)
    FileUtils::cp('src/ruby/Gemfile', 'docker/ruby/')
end
if PROFILE.include?(:neo4j)
    FileUtils::mkpath(NEO4J_DATA_PATH)
end
FileUtils::mkpath(RAW_PATH)
FileUtils::mkpath(File.join(RAW_PATH, 'uploads'))
FileUtils::mkpath(GEN_PATH)

system("docker-compose --project-name #{PROJECT_NAME_FIXED} #{ARGV.join(' ')}")
