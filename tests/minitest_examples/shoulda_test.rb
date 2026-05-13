# frozen_string_literal: true

require "minitest/autorun"
require "active_support/test_case"
require "shoulda/context"

class ShouldaTest < ActiveSupport::TestCase
  should "do a thing" do
    assert true
  end

  context "addition" do
    should "add two numbers" do
      assert_equal 2 + 2, 4
    end
  end
end
