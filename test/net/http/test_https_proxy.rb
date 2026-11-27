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
end
