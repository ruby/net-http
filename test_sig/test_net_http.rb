require "net/http"
require "socket"
require "stringio"
require "uri"
require "test_helper"

module NetHTTPTypeTestSupport
  class Server
    attr_reader :uri

    def initialize(host = "127.0.0.1")
      @server = TCPServer.open(host, 0)
      @uri = URI("http://#{host}:#{@server.local_address.ip_port}/")
      @thread = Thread.new do
        loop do
          handle_session(@server.accept)
        end
      rescue IOError, Errno::EBADF
      end
    end

    def finish
      @thread.kill
      @thread.join
      @server.close
    rescue IOError, Errno::EBADF
    end

    private

    def handle_session(socket)
      content_length = nil

      while (line = socket.gets)
        content_length = line.split(":", 2)[1].strip.to_i if line.start_with?("Content-Length:")
        break if line == "\r\n"
      end

      socket.read(content_length) if content_length

      body = "ok"
      socket.write(
        "HTTP/1.1 200 OK\r\n" \
        "Connection: close\r\n" \
        "Content-Type: text/plain\r\n" \
        "Set-Cookie: session=1\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "\r\n" \
        "#{body}"
      )
    ensure
      socket.close
    end
  end

  def with_server(host = "127.0.0.1")
    server = Server.new(host)
    yield server.uri
  ensure
    server&.finish
  end
end

class NetHTTPSingletonRBSTest < NetHTTPRBSTestCase
  include NetHTTPTypeTestSupport

  testing "singleton(::Net::HTTP)"

  def test_singleton_api
    previous_stdout = $stdout
    $stdout = StringIO.new

    with_server do |uri|
      assert_send_type "(URI::Generic) -> nil",
                       Net::HTTP, :get_print, uri
      assert_send_type "(String, String, Integer) -> nil",
                       Net::HTTP, :get_print, uri.host, "/", uri.port
      assert_send_type "(URI::Generic, Hash[String, String]) -> String",
                       Net::HTTP, :get, uri, { "Accept" => "text/plain" }
      assert_send_type "(URI::Generic, Hash[Symbol, String]) -> Net::HTTPResponse",
                       Net::HTTP, :get_response, uri, { Accept: "text/plain" }
      assert_send_type "(URI, String, Hash[String, String]) -> Net::HTTPResponse",
                       Net::HTTP, :post, uri, "payload", "Content-Type" => "text/plain"
      assert_send_type "(URI, Hash[String, Symbol]) -> Net::HTTPResponse",
                       Net::HTTP, :post_form, uri, { "q" => :ruby }

      http = assert_send_type "(String, Integer) -> Net::HTTP",
                              Net::HTTP, :start, uri.host, uri.port
      http.finish if http.started?

      assert_send_type "(String, Integer) { (Net::HTTP) -> Class } -> Class",
                       Net::HTTP, :start, uri.host, uri.port do |net_http|
        net_http.class
      end
    end

    assert_send_type "(String, Integer, nil, nil, nil, nil, nil) -> Net::HTTP",
                     Net::HTTP, :new, "127.0.0.1", 80, nil, nil, nil, nil, nil
  ensure
    $stdout = previous_stdout
  end
end

class NetHTTPInstanceRBSTest < NetHTTPRBSTestCase
  include NetHTTPTypeTestSupport

  testing "::Net::HTTP"

  def test_attribute_api
    http = Net::HTTP.new("127.0.0.1", 80)

    assert_send_type "() -> String", http, :inspect
    assert_send_type "() -> String", http, :address
    assert_send_type "() -> Integer", http, :port
    assert_send_type "() -> nil", http, :ipaddr
    assert_send_type "(String) -> void", http, :ipaddr=, "127.0.0.1"
    assert_send_type "() -> Integer", http, :open_timeout
    assert_send_type "() -> Integer", http, :read_timeout
    assert_send_type "(Integer) -> void", http, :read_timeout=, 10
    assert_send_type "() -> Integer", http, :write_timeout
    assert_send_type "(Integer) -> void", http, :write_timeout=, 10
    assert_send_type "() -> nil", http, :continue_timeout
    assert_send_type "(Integer) -> void", http, :continue_timeout=, 10
    assert_send_type "() -> Integer", http, :max_retries
    assert_send_type "(Integer) -> void", http, :max_retries=, 10
    assert_send_type "() -> Integer", http, :keep_alive_timeout
    assert_send_type "() -> bool", http, :started?
    assert_send_type "() -> bool", http, :active?
    assert_send_type "() -> bool", http, :use_ssl?
    assert_send_type "(bool) -> void", http, :use_ssl=, true
    assert_send_type "() -> bool", http, :proxy?
    assert_send_type "() -> bool", http, :proxy_from_env?
    assert_send_type "() -> nil", http, :proxy_uri
    assert_send_type "() -> nil", http, :proxy_address
    assert_send_type "() -> nil", http, :proxy_port
    assert_send_type "() -> nil", http, :proxy_user
    assert_send_type "() -> nil", http, :proxy_pass
    assert_send_type "(IO) -> void", http, :set_debug_output, $stderr
  end

  def test_request_api
    with_server do |uri|
      http = Net::HTTP.start(uri.host, uri.port)

      assert_send_type "(String) -> Net::HTTPResponse", http, :get, "/"
      assert_send_type "(String, Hash[String, String]) -> Net::HTTPResponse",
                       http, :get, "/", { "Accept" => "text/plain" }
      assert_send_type "(String) { (String) -> String } -> Net::HTTPResponse",
                       http, :get, "/" do |body|
        body
      end
      assert_send_type "(String) -> Net::HTTPResponse", http, :head, "/"
      assert_send_type "(String, String) -> Net::HTTPResponse", http, :post, "/", "payload"
      assert_send_type "(String, String, Hash[String, String]) -> Net::HTTPResponse",
                       http, :request_post, "/", "payload", { "Content-Type" => "text/plain" }
      assert_send_type "(String) { (Net::HTTPResponse) -> String? } -> Net::HTTPResponse",
                       http, :request_get, "/" do |response|
        response.body
      end
      assert_send_type "(String, String) -> Net::HTTPResponse",
                       http, :send_request, "GET", "/"
      assert_send_type "(Net::HTTPRequest) -> Net::HTTPResponse",
                       http, :request, Net::HTTP::Get.new(uri)
    ensure
      http.finish if http&.started?
    end
  end
end

class NetHTTPRequestRBSTest < NetHTTPRBSTestCase
  include NetHTTPTypeTestSupport

  testing "::Net::HTTPRequest"

  def test_request_attributes_and_headers
    uri = URI("http://127.0.0.1/")
    request = Net::HTTP::Get.new(uri)

    assert_send_type "() -> String", request, :inspect
    assert_send_type "() -> String", request, :method
    assert_send_type "() -> String", request, :path
    assert_send_type "() -> URI::Generic", request, :uri
    assert_send_type "() -> bool", request, :decode_content
    assert_send_type "() -> bool", request, :request_body_permitted?
    assert_send_type "() -> bool", request, :response_body_permitted?
    assert_send_type "() -> nil", request, :body
    assert_send_type "(String) -> void", request, :body=, "payload"
    assert_send_type "() -> nil", request, :body_stream
    assert_send_type "(untyped) -> untyped", request, :body_stream=, StringIO.new
    assert_send_type "(String) -> nil", request, :[], "Content-Type"
    assert_send_type "(String, untyped) -> void", request, :[]=, "Content-Type", "text/plain"
    assert_send_type "(String, untyped) -> void", request, :add_field, "X-Test", "1"
    assert_send_type "(String) -> bool", request, :key?, "X-Test"
    assert_send_type "() -> nil", request, :range
    assert_send_type "(Range[Integer]) -> Range[Integer]", request, :set_range, 0..10
    assert_send_type "(Integer) -> void", request, :content_length=, 10
    assert_send_type "(String) -> void", request, :set_content_type, "text/plain"
    assert_send_type "(Hash[untyped, untyped]) -> void", request, :set_form_data, { "q" => "ruby" }
    assert_send_type "(Hash[untyped, untyped]) -> void", request, :set_form, { "q" => "ruby" }
    assert_send_type "(String account, String password) -> void",
                     request, :basic_auth, "username", "password"
    assert_send_type "(String account, String password) -> void",
                     request, :proxy_basic_auth, "username", "password"
    assert_send_type "() -> bool", request, :connection_close?
    assert_send_type "() -> bool", request, :connection_keep_alive?
    assert_send_type "() { (String, String) -> String } -> Hash[String, Array[String]]",
                     request, :each_header do |key, value|
      "#{key}:#{value}"
    end
    assert_send_type "() -> Enumerator[[String, String], Hash[String, Array[String]]]",
                     request, :each_header
    assert_send_type "() -> Hash[String, Array[String]]", request, :to_hash
  end

  def test_response_header_helpers
    with_server do |uri|
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request_get("/") }

      assert_send_type "(String) -> Array[String]",
                       response, :get_fields, "Set-Cookie"
      assert_send_type "(String) { (String) -> String } -> String",
                       response, :fetch, "Set-Cookie" do |value|
        value
      end
      assert_send_type "(String) -> Array[String]",
                       response, :delete, "Set-Cookie"
    end
  end
end

class NetHTTPResponseRBSTest < NetHTTPRBSTestCase
  include NetHTTPTypeTestSupport

  testing "::Net::HTTPResponse"

  class SingletonTest < NetHTTPRBSTestCase
    testing "singleton(::Net::HTTPResponse)"

    def test_singleton_api
      assert_send_type "() -> bool", Net::HTTPSuccess, :body_permitted?
    end
  end

  def response
    with_server do |uri|
      Net::HTTP.get_response(uri)
    end
  end

  def test_response_api
    assert_send_type "() -> String", response, :http_version
    assert_send_type "() -> String", response, :code
    assert_send_type "() -> String", response, :message
    assert_send_type "() -> String", response, :msg
    assert_send_type "() -> URI::Generic", response, :uri
    assert_send_type "() -> bool", response, :decode_content
    assert_send_type "() -> String", response, :inspect
    assert_send_type "() -> untyped", response, :code_type
    assert_send_type "() -> nil", response, :value
    assert_send_type "(URI::Generic) -> void", response, :uri=, URI("http://127.0.0.1/next")
    assert_send_type "() -> String", response, :body
    assert_send_type "(String) -> void", response, :body=, "payload"
    assert_send_type "() -> String", response, :entity
  end
end
