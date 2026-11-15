require "test_helper"

class RaiseAssertionsTest < TestCase
  test "assert_nothing_raised counts as an assertion and returns the value of the block" do
    before = assertions
    assert_equal 42, assert_nothing_raised { 42 }
    assert_equal before + 2, assertions
  end

  test "assert_nothing_raised fails with the class, message and origin of the exception" do
    error = assert_raises(Minitest::Assertion) do
      assert_nothing_raised("Closing the ZIP") { raise ArgumentError, "bad offset" }
    end
    assert_match(/Closing the ZIP/, error.message)
    assert_match(/Expected nothing to be raised, but got ArgumentError: bad offset/, error.message)
    assert_match(/raise_assertions_test\.rb/, error.message)
  end

  test "assert_nothing_raised lets failed assertions and skips of the block through as they are" do
    failure = assert_raises(Minitest::Assertion) do
      assert_nothing_raised { assert_equal 1, 2 }
    end
    refute_match(/Expected nothing to be raised/, failure.message)

    assert_raises(Minitest::Skip) do
      assert_nothing_raised { skip "not today" }
    end
  end
end
