require "simplecov"
SimpleCov.start "rails" do
  add_filter "/app/channels/"
  add_filter "/app/jobs/application_job.rb"
  add_filter "/app/models/application_record.rb"
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"
require "timecop"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
