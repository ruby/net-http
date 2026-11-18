require 'test/unit'
require 'net/http'
require 'stringio'

class TestNetHTTPWriteError < Test::Unit::TestCase
  class MockHTTP < Net::HTTP
    attr_accessor :next_socket

    private

    def connect
      raise 'unexpected reconnect' unless @next_socket
      @socket = @next_socket
      @next_socket = nil
    end
  end

  class MockIO < StringIO
    attr_reader :write_count, :wait_timeout

    def initialize(response, write_error, read_error)
      super(response)
      @write_error = write_error
      @read_error = read_error
      @write_count = 0
    end

    def write_nonblock(str, exception: true)
      @write_count += 1
      raise @write_error if @write_error && @write_count == 2
      str.bytesize
    end

    def read_nonblock(*args, **kwargs)
      sleep if @read_error == :block
      return :wait_readable if @read_error == :wait_readable
      raise @read_error if @read_error
      super
    end

    def to_io
      self
    end

    def wait_readable(timeout)
      @wait_timeout = timeout
      nil
    end
  end

  class FailingSource
    attr_reader :read_count

    def initialize(error)
      @error = error
      @read_count = 0
    end

    def read(*)
      @read_count += 1
      raise @error
    end
  end

  class SizedFailingSource < FailingSource
    def size
      32
    end
  end

  def setup
    @connections = []
    @write_error = Errno::ECONNRESET.new('request write')
  end

  def teardown
    @connections.each { |io| io.close unless io.closed? }
  end

  def connection(response, write_error: @write_error, read_error: nil)
    io = MockIO.new(response, write_error, read_error)
    @connections << io
    http = MockHTTP.new('example.com', 80, nil)
    http.instance_variable_set(:@socket, Net::BufferedIO.new(io))
    http.instance_variable_set(:@started, true)
    [http, io]
  end

  def response(code = '413 Content Too Large', body = 'rejected')
    "HTTP/1.1 #{code}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def test_successful_write
    http, io = connection(response('200 OK', 'accepted'), write_error: nil)
    res = http.post('/', 'request body')
    assert_equal '200', res.code
    assert_equal 'accepted', res.body
    assert_equal 2, io.write_count
    assert_not_predicate io, :closed?
  end

  def test_broken_pipe_recovers_response
    http, io = connection(response, write_error: Errno::EPIPE.new)
    res = http.post('/', 'request body')
    assert_equal '413', res.code
    assert_equal 'rejected', res.body
    assert_equal 2, io.write_count
  end

  def test_broken_pipe_without_response_preserves_read_error
    http, io = connection('', write_error: Errno::EPIPE.new)
    assert_raise(EOFError) { http.post('/', 'request body') }
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_broken_pipe_preserves_eof_terminated_header_behavior
    http, io = connection("HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\n", write_error: Errno::EPIPE.new)
    assert_equal '413', http.post('/', 'request body').code
    assert_equal 2, io.write_count
  end

  def test_successful_write_preserves_malformed_response_error
    http, io = connection("not HTTP\r\n\r\n", write_error: nil)
    assert_raise(Net::HTTPBadResponse) { http.post('/', 'request body') }
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_reset_recovers_response_without_resending_post
    http, io = connection(response)
    res = http.request(Net::HTTP::Post.new(URI('http://example.com/')), 'request body')
    assert_equal '413', res.code
    assert_equal 'rejected', res.body
    assert_equal URI('http://example.com/'), res.uri
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
    assert_nil http.instance_variable_get(:@last_communicated)
  end

  def test_reset_recovers_success_response
    http, io = connection(response('200 OK', 'accepted'))
    res = http.post('/', 'request body')
    assert_equal '200', res.code
    assert_equal 'accepted', res.body
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_reset_reads_informational_responses_before_final_response
    http, io = connection("HTTP/1.1 100 Continue\r\n\r\n" + response)
    res = http.post('/', 'request body')
    assert_equal '413', res.code
    assert_equal 'rejected', res.body
    assert_equal 2, io.write_count
  end

  data(
    'empty' => '',
    'incomplete headers' => "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\n",
    'malformed status' => "not HTTP\r\n\r\n",
    'malformed header' => "HTTP/1.1 413 Content Too Large\r\nnot a header\r\n\r\n",
    'invalid header name' => "HTTP/1.1 413 Content Too Large\r\nX-\x00: value\r\n\r\n",
    'informational only' => "HTTP/1.1 100 Continue\r\n\r\n",
    'too many informational responses' => "HTTP/1.1 100 Continue\r\n\r\n" * (Net::HTTPResponse::MAX_INFORMATIONAL_RESPONSES + 1),
  )
  def test_reset_without_valid_final_response_preserves_write_error(data)
    http, io = connection(data)
    error = assert_raise(Errno::ECONNRESET) { http.post('/', 'request body') }
    assert_same @write_error, error
    assert_match(/write_nonblock/, error.backtrace.first)
    assert_predicate io, :closed?
  end

  data(
    'reset' => Errno::ECONNRESET.new('response read'),
    'closed' => IOError.new('closed stream'),
  )
  def test_reset_with_read_error_preserves_write_error(data)
    http, io = connection('', read_error: data)
    error = assert_raise(Errno::ECONNRESET) { http.post('/', 'request body') }
    assert_same @write_error, error
    assert_predicate io, :closed?
  end

  def test_reset_recovery_uses_read_timeout
    http, io = connection('', read_error: :wait_readable)
    http.read_timeout = 0.25
    error = assert_raise(Errno::ECONNRESET) { http.post('/', 'request body') }
    assert_same @write_error, error
    assert_equal 0.25, io.wait_timeout
    assert_predicate io, :closed?
  end

  def test_reset_recovery_preserves_external_timeout
    timeout = Timeout::Error.new('request deadline')
    http, io = connection('', read_error: timeout)
    error = assert_raise(Timeout::Error) { http.post('/', 'request body') }
    assert_same timeout, error
    assert_predicate io, :closed?
  end

  def test_reset_does_not_hide_response_body_error
    http, io = connection("HTTP/1.1 413 Content Too Large\r\nContent-Length: 100\r\n\r\nshort")
    http.ignore_eof = false
    assert_raise(EOFError) { http.post('/', 'request body') }
    assert_predicate io, :closed?
  end

  def test_reset_does_not_hide_malformed_chunked_body
    http, io = connection("HTTP/1.1 413 Content Too Large\r\nTransfer-Encoding: chunked\r\n\r\nxyz\r\n")
    assert_raise(Net::HTTPBadResponse) { http.post('/', 'request body') }
    assert_predicate io, :closed?
  end

  data(
    'application error' => RuntimeError.new('callback'),
    'reset' => Errno::ECONNRESET.new('callback'),
    'bad response' => Net::HTTPBadResponse.new('callback'),
  )
  def test_reset_does_not_hide_callback_error(data)
    http, io = connection(response)
    called = 0
    error = assert_raise(data.class) do
      http.request(Net::HTTP::Put.new('/'), 'request body') do |res|
        called += 1
        assert_equal '413', res.code
        raise data
      end
    end
    assert_same data, error
    assert_equal 1, called
    assert_predicate io, :closed?
  end

  def test_reset_allows_streaming_response_body
    http, io = connection(response)
    body = +''
    res = http.request(Net::HTTP::Post.new('/'), 'request body') do |r|
      r.read_body { |chunk| body << chunk }
    end
    assert_equal '413', res.code
    assert_equal 'rejected', body
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  data('content length' => false, 'chunked' => true)
  def test_upload_source_reset_is_not_recovered(chunked)
    http, io = connection(response('200 OK', 'accepted'), write_error: nil)
    error = Errno::ECONNRESET.new('upload source')
    source = FailingSource.new(error)
    req = Net::HTTP::Post.new('/')
    req.body_stream = source
    if chunked
      req['Transfer-Encoding'] = 'chunked'
    else
      req.content_length = 32
    end
    assert_same error, assert_raise(Errno::ECONNRESET) { http.request(req) }
    assert_equal 1, source.read_count
    assert_equal 1, io.write_count
    assert_predicate io, :closed?
  end

  def test_buffered_multipart_upload_source_reset_is_not_recovered
    http, io = connection(response('200 OK', 'accepted'), write_error: nil)
    error = Errno::ECONNRESET.new('multipart upload source')
    source = FailingSource.new(error)
    req = Net::HTTP::Post.new('/')
    req.set_form([['file', source, {filename: 'upload.txt'}]], 'multipart/form-data')
    assert_same error, assert_raise(Errno::ECONNRESET) { http.request(req) }
    assert_equal 1, source.read_count
    assert_equal 0, io.write_count
    assert_predicate io, :closed?
  end

  data(
    'stream' => :stream,
    'chunked stream' => :chunked_stream,
    'buffered multipart' => :multipart,
    'chunked multipart' => :chunked_multipart,
  )
  def test_destination_reset_recovers_response_for_uploads(kind)
    http, io = connection(response)
    req = Net::HTTP::Post.new('/')
    source = StringIO.new('request body')
    case kind
    when :stream, :chunked_stream
      req.body_stream = source
      req.content_length = source.size if kind == :stream
    else
      req.set_form([['file', source, {filename: 'upload.txt'}]], 'multipart/form-data')
    end
    req['Transfer-Encoding'] = 'chunked' if kind == :chunked_stream || kind == :chunked_multipart
    res = http.request(req)
    assert_equal '413', res.code
    assert_equal 'rejected', res.body
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
    assert_not_predicate source, :closed?
  end

  data('read' => false, 'copy stream' => true)
  def test_multipart_upload_source_reset_is_not_recovered(sized)
    http, io = connection(response('200 OK', 'accepted'), write_error: nil)
    error = Errno::ECONNRESET.new('multipart upload source')
    source = (sized ? SizedFailingSource : FailingSource).new(error)
    req = Net::HTTP::Post.new('/')
    req['Transfer-Encoding'] = 'chunked'
    req.set_form([['file', source, {filename: 'upload.txt'}]], 'multipart/form-data')
    assert_same error, assert_raise(Errno::ECONNRESET) { http.request(req) }
    assert_equal 1, source.read_count
    assert_operator io.write_count, :>, 1
    assert_predicate io, :closed?
  end

  def test_reset_callback_break_closes_recovery_socket
    http, io = connection(response)
    result = http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
      assert_equal '413', res.code
      break :left_callback
    end
    assert_equal :left_callback, result
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_reset_callback_throw_closes_recovery_socket
    http, io = connection(response)
    result = catch(:done) do
      http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
        throw :done, res.code
      end
    end
    assert_equal '413', result
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def request_with_callback_return(http)
    http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
      return res.code
    end
  end

  def test_reset_callback_return_closes_recovery_socket
    http, io = connection(response)
    assert_equal '413', request_with_callback_return(http)
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_actual_timeout_during_recovery_closes_socket
    http, io = connection('', read_error: :block)
    assert_raise(Timeout::Error) do
      Timeout.timeout(EnvUtil.apply_timeout_scale(0.1)) { http.post('/', 'request body') }
    end
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_actual_timeout_in_recovered_response_callback_closes_socket
    http, io = connection(response)
    called = 0
    assert_raise(Timeout::Error) do
      Timeout.timeout(EnvUtil.apply_timeout_scale(0.1)) do
        http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
          called += 1
          assert_equal '413', res.code
          sleep
        end
      end
    end
    assert_equal 1, called
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_reset_cleanup_closes_only_affected_socket
    http, io = connection(response)
    other_http, other_io = connection(response, write_error: nil)
    other_socket = other_http.instance_variable_get(:@socket)
    result = catch(:done) do
      http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
        http.instance_variable_set(:@socket, other_socket)
        throw :done, res.code
      end
    end
    assert_equal '413', result
    assert_predicate io, :closed?
    assert_not_predicate other_io, :closed?
  end

  def test_callback_break_without_reset_does_not_close_socket
    http, io = connection(response, write_error: nil)
    result = http.request(Net::HTTP::Post.new('/'), 'request body') do |res|
      break res.code
    end
    assert_equal '413', result
    assert_equal 2, io.write_count
    assert_not_predicate io, :closed?
  end

  def test_reset_without_response_retries_idempotent_request
    http, io = connection('')
    _other_http, next_io = connection(response('200 OK', 'accepted'), write_error: nil)
    http.next_socket = Net::BufferedIO.new(next_io)
    res = http.request(Net::HTTP::Put.new('/'), 'request body')
    assert_equal '200', res.code
    assert_equal 'accepted', res.body
    assert_equal 2, io.write_count
    assert_equal 2, next_io.write_count
    assert_predicate io, :closed?
    assert_not_predicate next_io, :closed?
  end

  def test_reset_without_response_honors_max_retries
    http, io = connection('')
    http.max_retries = 0
    error = assert_raise(Errno::ECONNRESET) do
      http.request(Net::HTTP::Put.new('/'), 'request body')
    end
    assert_same @write_error, error
    assert_equal 2, io.write_count
    assert_predicate io, :closed?
  end

  def test_reset_without_response_exhausts_idempotent_retries
    http, io = connection('')
    next_error = Errno::ECONNRESET.new('retried request write')
    _other_http, next_io = connection('', write_error: next_error)
    http.next_socket = Net::BufferedIO.new(next_io)
    http.max_retries = 1
    error = assert_raise(Errno::ECONNRESET) do
      http.request(Net::HTTP::Put.new('/'), 'request body')
    end
    assert_same next_error, error
    assert_equal 2, io.write_count
    assert_equal 2, next_io.write_count
    assert_predicate io, :closed?
    assert_predicate next_io, :closed?
  end

  def test_next_request_reconnects_after_reset_recovery
    http, io = connection(response)
    _other_http, next_io = connection(response('200 OK', 'accepted'), write_error: nil)
    http.next_socket = Net::BufferedIO.new(next_io)
    assert_equal '413', http.post('/', 'request body').code
    assert_equal '200', http.post('/', 'another request body').code
    assert_equal 2, io.write_count
    assert_equal 2, next_io.write_count
    assert_predicate io, :closed?
  end
end
