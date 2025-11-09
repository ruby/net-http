# frozen_string_literal: true
module Net
  # Net::HTTP exception class.
  # You cannot use Net::HTTPExceptions directly; instead, you must use
  # its subclasses.
  module HTTPExceptions
    # Valid keys for pattern matching via #deconstruct_keys.
    PATTERN_MATCHING_KEYS = %i[message response].freeze

    def initialize(msg, res)   #:nodoc:
      super msg
      @response = res
    end
    attr_reader :response
    alias data response    #:nodoc: obsolete

    # Returns a hash of exception attributes for pattern matching.
    #
    # Valid keys are: +:message+, +:response+
    #
    # Example:
    #
    #   begin
    #     http.request(req)
    #   rescue => e
    #     case e
    #     in HTTPRetriableError[response: { code: '503' }]
    #       retry_with_backoff
    #     in HTTPClientException[response: { code: '404' }]
    #       handle_not_found
    #     end
    #   end
    #
    def deconstruct_keys(keys)
      valid_keys = keys ? PATTERN_MATCHING_KEYS & keys : PATTERN_MATCHING_KEYS
      valid_keys.to_h { |key| [key, public_send(key)] }
    end
  end

  class HTTPError < ProtocolError
    include HTTPExceptions
  end

  class HTTPRetriableError < ProtoRetriableError
    include HTTPExceptions
  end

  class HTTPClientException < ProtoServerError
    include HTTPExceptions
  end

  class HTTPFatalError < ProtoFatalError
    include HTTPExceptions
  end

  # We cannot use the name "HTTPServerError", it is the name of the response.
  HTTPServerException = HTTPClientException # :nodoc:
  deprecate_constant(:HTTPServerException)
end
