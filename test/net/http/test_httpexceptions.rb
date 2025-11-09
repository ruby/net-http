# frozen_string_literal: false
require 'net/http'
require 'test/unit'

class HTTPExceptionsTest < Test::Unit::TestCase
  def test_deconstruct_keys
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    error = Net::HTTPError.new('test error', response)

    keys = error.deconstruct_keys(nil)
    assert_equal 'test error', keys[:message]
    assert_equal response, keys[:response]
  end

  def test_deconstruct_keys_with_specific_keys
    response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
    error = Net::HTTPClientException.new('not found', response)

    keys = error.deconstruct_keys([:message])
    assert_equal({message: 'not found'}, keys)
  end

  def test_pattern_matching
    response = Net::HTTPServiceUnavailable.new('1.1', '503', 'Service Unavailable')
    error = Net::HTTPRetriableError.new('service unavailable', response)

    begin
      matched = instance_eval <<~RUBY, __FILE__, __LINE__ + 1
        case error
        in message: /unavailable/, response:
          true
        else
          false
        end
      RUBY
      assert_equal true, matched
    rescue SyntaxError
      omit "Pattern matching requires Ruby 2.7+"
    end
  end

  def test_pattern_matching_with_response_attributes
    response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
    error = Net::HTTPClientException.new('not found', response)

    begin
      matched = instance_eval <<~RUBY, __FILE__, __LINE__ + 1
        case error
        in response: res if res.code == '404'
          true
        else
          false
        end
      RUBY
      assert_equal true, matched
    rescue SyntaxError
      omit "Pattern matching requires Ruby 2.7+"
    end
  end
end
