require "js"
require "securerandom"

ENV["ACTIVE_RECORD_ADAPTER"] = "pglite"
# ENV["ACTIVE_RECORD_ADAPTER"] = "nulldb"
ENV["DB_POOL"] = "1"
ENV["RAILS_ENV"] = "production"
ENV["RAILS_LOG_LEVEL"] = "debug"

ENV["RAILS_WEB"] = "1"

ENV["LOCAL_DOMAIN"] = "localhost"
ENV["SINGLE_USER_MODE"] = "true"
ENV["SECRET_KEY_BASE"] = "d4398e4af52f1fc5be5c3c8764e9ecce7beac5462826cb8b649373b2aad5a0f133598ed817c4e9931e943041460d6b6eda40a854e825e1bbd510c4594b1538f2"
ENV["OTP_SECRET"] = "bd85e7dabd3871e38bed0c226f52b70e178b8672f26e82e3eab9693aef85efd868ce209c12e9014c4f6c5dabe238524b2a8f30c01a53c596b39799e7e1ec0949"
ENV["VAPID_PRIVATE_KEY"] = "tNlzaQf/SppJYEV+Wwei0gBxHXwylml5TofxxO2zclw="
ENV["VAPID_PUBLIC_KEY"] = "aaAAcyTvTWoSmNQHqHubPhQL3h7PAmGa4V2aDmX37Y1v1UEgl3420BRJ+zmMYjiOmoqYJ+Q5/zQMz5MWQjocyu8="
ENV["DB_HOST"] = "/var/run/postgresql"
ENV["DB_PORT"] = "5432"
ENV["DB_NAME"] = "mastodon_production"
ENV["DB_USER"] = "mastodon"
ENV["DB_PASS"] = ""
ENV["REDIS_HOST"] = "localhost"
ENV["REDIS_PORT"] = "6379"
ENV["REDIS_PASSWORD"] = ""
ENV["SMTP_SERVER"] = "smtp.mailgun.org"
ENV["SMTP_PORT"] = "587"
ENV["SMTP_LOGIN"] = ""
ENV["SMTP_PASSWORD"] = ""
ENV["SMTP_AUTH_METHOD"] = "plain"
ENV["SMTP_OPENSSL_VERIFY_MODE"] = "none"
ENV["SMTP_ENABLE_STARTTLS"] = "auto"
ENV["SMTP_FROM_ADDRESS"] = "Mastodon <notifications@localhost>"
ENV["UPDATE_CHECK_URL"]=""

class Thread
  def self.new(...)
    f = Fiber.new(...)
    def f.value = resume
    f
  end
end

module HTTP
end
module HTTP
  class Error < StandardError; end
  class ConnectionError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end
  class StateError < ResponseError; end
  class TimeoutError < Error; end
  class ConnectTimeoutError < TimeoutError; end
  class HeaderError < Error; end
end

module Sidekiq
  def self.server?
    false
  end
end

require "bundler/setup"
require "connection_pool"
require "zeitwerk"
require "active_record"
require "nulldb/rails"

module Kernel
  module_function

  alias_method :rails_web_original_require, :require
  class << self
    alias_method :rails_web_original_require, :require
  end

  def require(path)
    remote_paths = %w[app config db lib public]
    development_mode = JS.global[:RAILS_WEB_DEVELOPMENT] != JS::Undefined
    load_from_remote = development_mode && path.end_with?(".rb") && remote_paths.any? do |remote_path|
      path.start_with?("/rails/#{remote_path}")
    end

    if load_from_remote
      if $LOADED_FEATURES.include?(path)
        return false
      end
      puts "[rails_web] require: #{path}"
      response = JS.global.fetch(path).await
      unless response[:status].to_i == 200
        raise LoadError, "cannot load such file from remote -- #{path} (status: #{response[:status]})"
      end
      code = response.text.await.to_s
      $LOADED_FEATURES << path
      Kernel.eval(code, TOPLEVEL_BINDING, path)
      return true
    end

    if path == "bcrypt_ext"
      return rails_web_original_require("/bundle/ruby/3.4.0+0/extensions/wasm32-wasi/3.4.0+0-static/bcrypt-3.1.20/bcrypt_ext.so")
    end
    rails_web_original_require(path)
  end
end

module Kernel
  alias_method :rails_web_original_require_pglite_adapter, :require
  def require(path)
    if path == "pg" || path == "active_record/connection_adapters/pglite_adapter"
      return true
    end
    rails_web_original_require_pglite_adapter(path)
  end

  alias_method :rails_web_original_gem_pglite_adapter, :gem
  def gem(name, version = nil)
    if name == "pg"
      return true
    end
    rails_web_original_gem_pglite_adapter(name, version)
  end
end

module PG
  PQTRANS_IDLE = 0
  PQTRANS_ACTIVE = 1
  PQTRANS_INTRANS = 2
  PQTRANS_INERROR = 3
  PQTRANS_UNKNOWN = 4
  class SimpleDecoder; end
  class Error < StandardError; end

  class Connection
    def self.quote_ident(ident)
      ident
    end
  end
end

require "active_record/connection_adapters/postgresql_adapter"

Kernel.eval(JS.global.fetch("/pglite.rb").await.text.await.to_s, TOPLEVEL_BINDING, "/pglite.rb")

require "/rails/config/environment"
Rails.autoloaders.log!

class Status
  before_create do
    self.created_at = Time.now.utc
    self.updated_at = Time.now.utc
    self.id = Mastodon::Snowflake.id_at(self.created_at)
  end
end

Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = true
Rails.application.env_config['action_dispatch.show_exceptions']          = true

$rack_handler = proc do |url, request, cookie|
  headers = {
    "HTTP_HOST" => "localhost",
    "REMOTE_ADDR" => "127.0.0.1",
    "HTTP_COOKIE" => cookie.to_s,
    method: request[:method].to_s.to_sym
  }
  request[:headers].entries.to_a.each do |kv|
    key = kv[0]
    value = kv[1]
    headers["HTTP_" + key.to_s.upcase.tr("-", "_")] = value.to_s
  end
  headers["HTTP_ORIGIN"] = "http://localhost"
  headers["CONTENT_TYPE"] = headers["HTTP_CONTENT_TYPE"]

  request_body = JS.global[:Response].new(request[:body]).text.await.to_s
  puts "[rails_web] request body: #{request_body}"
  env = Rack::MockRequest.env_for(
    url.to_s, headers.merge(
      input: request_body,
    )
  )
  puts "[rails_web] request env: #{env.inspect}"
  response = Rack::Response[*Rails.application.call(env)]
  status, headers, bodyiter = *response.finish
  puts "[rails_web] response status: #{status}, headers: #{headers.inspect}, bodyiter: #{bodyiter.inspect.size} bytes"
  body = ""
  bodyiter.each { |part| body += part }
  # Serve images as base64 from Ruby and decode back in JS
  if headers["Content-Type"] == "image/png"
    body = Base64.strict_encode64(body)
  end
  res = {
    status: status,
    headers: headers,
    body: body
  }
  res
end
