require "bundler/gem_tasks"
require "rake/testtask"
require "tmpdir"

Rake::TestTask.new(:test) do |t|
  t.libs << "test/lib"
  t.ruby_opts << "-rhelper"
  t.test_files = FileList["test/**/test_*.rb"]
end

desc "Type check with Steep"
task :steep do
  sh "steep check"
end

namespace :rbs do
  Rake::TestTask.new(:test) do |t|
    t.libs << "test_sig"
    t.ruby_opts << "-rtest_helper"
    t.test_files = FileList["test_sig/test_*.rb"]
  end

  desc "Update public RBS comments from local RDoc"
  task :annotate do
    Dir.mktmpdir do |tmpdir|
      sh "rdoc", "--ri", "--output", "#{tmpdir}/doc", "--root=.", "lib", "doc"
      sh "rbs", "annotate", "--no-system", "--no-gems", "--no-site", "--no-home",
         "-d", "#{tmpdir}/doc", "sig/net-http.rbs"
    end
  end
end

task :default => :test
