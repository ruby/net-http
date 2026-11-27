# frozen_string_literal: false
begin
  require 'net/https'
rescue LoadError
end
require 'test/unit'

return unless defined?(OpenSSL::SSL)

class HTTPSProxyTest < Test::Unit::TestCase
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

  def read_fixture(key)
    File.read(File.expand_path("../fixtures/#{key}", __dir__))
  end

  def test_https_proxy_ssl_connection
    with_ssl_proxy do |port, serv|
      client_thread = Thread.new {
        proxy = Net::HTTP.Proxy("localhost", port, 'user', 'password', true)
        http = proxy.new("foo.example.org", 8000)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.proxy_cert_store = proxy_cert_store
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
            "[ruby-core:96672]")
        ensure
          sock.close
        end
      }
      assert_join_threads([client_thread, server_thread])
    end
  end

  def test_https_proxy_rejects_untrusted_certificate
    assert_proxy_certificate_rejected("localhost", trusted: false)
  end

  def test_https_proxy_rejects_wrong_host_certificate
    assert_proxy_certificate_rejected("127.0.0.1", trusted: true)
  end

  def proxy_cert_store
    OpenSSL::X509::Store.new.tap {|store|
      store.add_cert(OpenSSL::X509::Certificate.new(read_fixture("cacert.pem")))
    }
  end

  def with_ssl_proxy
    TCPServer.open("127.0.0.1", 0) {|tcpserver|
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key = OpenSSL::PKey.read(read_fixture("server.key"))
      ctx.cert = OpenSSL::X509::Certificate.new(read_fixture("server.crt"))
      serv = OpenSSL::SSL::SSLServer.new(tcpserver, ctx)
      yield serv.addr[1], serv
    }
  end

  def assert_proxy_certificate_rejected(proxy_address, trusted:)
    with_ssl_proxy do |port, serv|
      proxy_request = nil
      client_error = nil
      client_thread = Thread.new {
        proxy = Net::HTTP.Proxy(proxy_address, port, 'user', 'password', true)
        http = proxy.new("foo.example.org", 8000)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.proxy_cert_store = proxy_cert_store if trusted
        begin
          http.start
        rescue => error
          client_error = error
        end
      }
      server_thread = Thread.new {
        begin
          sock = serv.accept
          proxy_request = sock.gets("\r\n\r\n")
        rescue EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, OpenSSL::SSL::SSLError
          proxy_request = nil
        ensure
          sock&.close
        end
      }
      assert_join_threads([client_thread, server_thread])
      assert_nil(proxy_request, "proxy received bytes before certificate rejection: #{proxy_request.inspect}")
      assert_kind_of(OpenSSL::SSL::SSLError, client_error)
    end
  end
end
