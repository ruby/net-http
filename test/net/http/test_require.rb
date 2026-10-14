# frozen_string_literal: false
require 'net/http'
require 'test/unit'

# Guards the autoload of Resolv in net/http. The checks run in a subprocess
# because this one has resolv loaded already.
class HTTPRequireTest < Test::Unit::TestCase
  RESOLV_LOADED = '$LOADED_FEATURES.any? { |f| File.basename(f) == "resolv.rb" }'

  def subprocess(script)
    lib = File.expand_path('../../../lib', __dir__)
    IO.popen([RbConfig.ruby, '-I', lib, '-e', script], &:read)
  end

  def test_requiring_net_http_does_not_load_resolv
    assert_equal 'false', subprocess("require 'net/http'; print #{RESOLV_LOADED}")
  end

  def test_resolv_is_still_reachable_after_requiring_net_http
    script = "require 'net/http'; print Resolv::IPv4::Regex.is_a?(Regexp)"
    assert_equal 'true', subprocess(script)
  end

  def test_referencing_resolv_loads_it
    script = "require 'net/http'; Resolv::IPv4::Regex; print #{RESOLV_LOADED}"
    assert_equal 'true', subprocess(script)
  end
end
