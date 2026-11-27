# frozen_string_literal: false
begin
  require 'net/https'
rescue LoadError
end
require 'test/unit'
require_relative 'utils'

return unless defined?(OpenSSL::SSL)

class TestNetHTTPSOverProxy < Test::Unit::TestCase
  def test_https_proxy_authentication
    TCPServer.open("127.0.0.1", 0) {|serv|
      _, port, _, _ = serv.addr
      client_thread = Thread.new {
        proxy = Net::HTTP.Proxy("127.0.0.1", port, 'user', 'password')
        http = proxy.new("foo.example.org", 8000)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        begin
          http.start
        rescue EOFError
        end
      }
      server_thread = Thread.new {
        sock = serv.accept
        begin
          proxy_request = sock.gets("\r\n\r\n")
          assert_equal(
            "CONNECT foo.example.org:8000 HTTP/1.1\r\n" +
            "Host: foo.example.org:8000\r\n" +
            "Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n" +
            "\r\n",
            proxy_request,
            "[ruby-dev:25673]")
        ensure
          sock.close
        end
      }
      assert_join_threads([client_thread, server_thread])
    }
  end


  def test_https_proxy_rejects_crlf_in_address
    TCPServer.open("127.0.0.1", 0) {|serv|
      _, port, _, _ = serv.addr
      client_thread = Thread.new {
        proxy = Net::HTTP.Proxy("127.0.0.1", port)
        http = proxy.new("foo.example.org\r\nX-Injected: 1\r\nbar.example.org", 8000)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        assert_raise(ArgumentError) { http.start }
      }
      server_thread = Thread.new {
        sock = serv.accept
        sock.close
      }
      assert_join_threads([client_thread, server_thread])
    }
  end
end

class TestNetHTTPSOverHTTPSProxy < Test::Unit::TestCase
  def self.read_fixture(key)
    File.read(File.expand_path("../fixtures/#{key}", __dir__))
  end

  PROXY_CERT = OpenSSL::X509::Certificate.new(read_fixture("server.crt"))
  SERVER_KEY = OpenSSL::PKey.read(read_fixture("server.key"))
  SERVER_CERT = OpenSSL::X509::Certificate.new(read_fixture("server_ip_san.crt"))
  CA_CERT = OpenSSL::X509::Certificate.new(read_fixture("cacert.pem"))
  TEST_STORE = OpenSSL::X509::Store.new.add_cert(CA_CERT)

  def teardown
    @server&.shutdown
  end

  def test_http_over_https_proxy
    proxy_port = spawn_https_proxy do |method, path, headers, socket|
      str = "#{method} #{path}"
      socket << "HTTP/1.1 200 OK\r\n"
      socket << "Content-Length: #{str.bytesize}\r\n\r\n"
      socket << str
    end

    http = Net::HTTP.new("example.test", 80, "localhost", proxy_port)
    http.proxy_use_ssl = true
    http.proxy_ssl_context.cert_store = TEST_STORE
    assert_equal("GET http://example.test/path", http.get("/path").body)
  end

  def test_https_over_https_proxy
    # omit "nested SSLSocket is not supported" unless OpenSSL::VERSION >= "4.1"
    Socket.open(:INET, :STREAM) do |io|
      ssl = OpenSSL::SSL::SSLSocket.new(io)
      begin
        OpenSSL::SSL::SSLSocket.new(ssl)
      rescue TypeError
        omit "nested SSLSocket is not supported"
      end
    end

    origin_context = OpenSSL::SSL::SSLContext.new
    origin_context.add_certificate(SERVER_CERT, SERVER_KEY)

    connect = nil
    proxy_port = spawn_https_proxy do |method, path, headers, socket|
      connect = "#{method} #{path}"
      socket << "HTTP/1.1 200 Connection Established\r\n\r\n"
      origin = OpenSSL::SSL::SSLSocket.new(socket, origin_context)
      origin.accept

      str = origin.gets("\r\n\r\n")
      origin << "HTTP/1.1 200 OK\r\n"
      origin << "Content-Length: #{str.bytesize}\r\n\r\n"
      origin << str
      origin.close
    end

    http = Net::HTTP.new("127.0.0.1", 443, "localhost", proxy_port)
    http.proxy_use_ssl = true
    http.proxy_ssl_context.cert_store = TEST_STORE
    http.use_ssl = true
    http.ssl_context.cert_store = TEST_STORE

    body = http.get("/path").body
    assert_equal("CONNECT 127.0.0.1:443", connect)
    assert_match(%r{^GET /path HTTP/1.1\r\n}, body)
    assert_match(%r{^Host: 127.0.0.1\r\n}, body)
  end

  def test_proxy_certificate_validation
    proxy_port = spawn_https_proxy {}
    http = Net::HTTP.new("example.test", 80, "127.0.0.1", proxy_port)
    http.proxy_use_ssl = true
    e = assert_raise(OpenSSL::SSL::SSLError) { http.start {} }
    assert_match(/certificate verify failed/, e.message)

    http = Net::HTTP.new("example.test", 80, "127.0.0.1", proxy_port)
    http.proxy_use_ssl = true
    http.proxy_ssl_context.cert_store = TEST_STORE
    e = assert_raise(OpenSSL::SSL::SSLError) { http.start {} }
    assert_match(/certificate verify failed|hostname .* does not match/, e.message)
  end

  def test_https_proxy_from_env
    TestNetHTTPUtils.clean_http_proxy_env do
      ENV["http_proxy"] = "https://localhost:8443"
      http = Net::HTTP.new("example.test")
      assert_predicate(http, :proxy_from_env?)
      assert_predicate(http, :proxy_use_ssl?)
    end
  end

  private

  def spawn_https_proxy(&handler)
    config = {
      'host' => '127.0.0.1',
      'ssl_enable' => true,
      'ssl_certificate' => PROXY_CERT,
      'ssl_private_key' => SERVER_KEY,
    }
    @server = TestNetHTTPUtils::HTTPServer.new(config, &handler)
    @server.start
    @server.port
  end
end
