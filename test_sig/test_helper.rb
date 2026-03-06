require "pathname"
require "test/unit"
require "rbs"
require "rbs/test"
require "rbs/unit_test"

module NetHTTPTestSigHelper
  extend self

  LOCAL_SIG_DIR = Pathname(__dir__).join("..", "sig").expand_path
  SUPPORT_LIBRARIES = %w[
    cgi
    net-protocol
    open-uri
    openssl
    resolv
    securerandom
    socket
    strscan
    tempfile
    timeout
    uri
    zlib
  ].freeze

  def env
    @env ||= begin
      loader = RBS::EnvironmentLoader.new
      loader.add(path: LOCAL_SIG_DIR)
      SUPPORT_LIBRARIES.each do |library|
        loader.add(library: library, version: nil)
      end
      RBS::Environment.from_loader(loader).resolve_type_names
    end
  end
end

class NetHTTPRBSTestCase < Test::Unit::TestCase
  include RBS::UnitTest::TypeAssertions

  def self.env
    NetHTTPTestSigHelper.env
  end

  def self.builder
    @builder ||= RBS::DefinitionBuilder.new(env: env)
  end
end
