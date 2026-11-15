require "test_helper"

class DescriptiveTestsTest < TestCase
  def build_test_case(&blk)
    Class.new(Minitest::Test) do
      extend DescriptiveTests
      # Keep these out of the actual run
      Minitest::Runnable.runnables.delete(self)
      def self.inherited(subclass)
        super
        Minitest::Runnable.runnables.delete(subclass)
      end
      define_singleton_method(:name) { "SampleTest" }
      class_eval(&blk)
    end
  end

  test "uses the description verbatim as the test method name" do
    test_case = build_test_case do
      test "writes a file, then (optionally) rolls back: 100% of the time!" do
        assert true
      end
    end

    assert_equal ["writes a file, then (optionally) rolls back: 100% of the time!"], test_case.runnable_methods
    result = test_case.new(test_case.runnable_methods.first).run
    assert_predicate result, :passed?
    assert_equal 1, result.assertions
  end

  test "still runs test_ methods defined with def" do
    test_case = build_test_case do
      test "described" do
      end

      def test_classic
      end
    end

    assert_equal ["described", "test_classic"], test_case.runnable_methods.sort
  end

  test "refuses a duplicate description" do
    error = assert_raises(ArgumentError) do
      build_test_case do
        test "same thing" do
        end
        test "same thing" do
        end
      end
    end
    assert_match(/already defined/, error.message)
  end

  test "refuses a description which would override an existing method" do
    error = assert_raises(ArgumentError) do
      build_test_case do
        test "name" do
        end
      end
    end
    assert_match(/would override/, error.message)
  end

  test "refuses a test without a block" do
    assert_raises(ArgumentError) do
      build_test_case { test "does nothing" }
    end
  end

  test "a context names itself after the enclosing test case and does not re-run its tests" do
    close_context = nil
    twice_context = nil
    test_case = build_test_case do
      test "outer" do
      end

      close_context = context "#close" do
        test "inner" do
        end

        twice_context = context "when called twice" do
          test "innermost" do
          end
        end
      end
    end

    assert_equal ["outer"], test_case.runnable_methods
    assert_equal "SampleTest #close", close_context.name
    assert_equal ["inner"], close_context.runnable_methods
    assert_equal "SampleTest #close when called twice", twice_context.name
    assert_equal ["innermost"], twice_context.runnable_methods
  end

  test "a context inherits setup and helper methods and may reuse a description of the enclosing test case" do
    nested = nil
    build_test_case do
      def setup
        @trail = [:outer_setup]
      end

      def helper_value
        42
      end

      test "does the thing" do
        flunk "must not run in the context"
      end

      nested = context "nested" do
        def setup
          super
          @trail << :inner_setup
        end

        test "does the thing" do
          assert_equal [:outer_setup, :inner_setup], @trail
          assert_equal 42, helper_value
        end
      end
    end

    result = nested.new("does the thing").run
    assert_predicate result, :passed?, result.failures.map(&:message).join
    assert_equal 2, result.assertions
  end

  test "a plain subclass inherits the tests of its parent" do
    parent = build_test_case do
      test "shared behavior" do
      end
    end
    child = Class.new(parent) do
      test "own behavior" do
      end
    end

    assert_equal ["own behavior", "shared behavior"], child.runnable_methods.sort
  end

  test "shuffles the tests by the seed of the run, regardless of the test_order of the test case" do
    test_case = build_test_case do
      def self.test_order
        :alpha
      end

      ("a".."p").each do |letter|
        test "case #{letter}" do
        end
      end
    end

    names = ("a".."p").map { |letter| "case #{letter}" }
    assert_equal names.shuffle(random: Random.new(Minitest.seed)), test_case.runnable_methods
    assert_equal test_case.runnable_methods, test_case.runnable_methods
  end
  test "remembers the tests which must not run in parallel with others" do
    nested = nil
    test_case = build_test_case do
      test "measures timings", parallel: false do
      end

      test "does not care" do
      end

      nested = context "nested" do
        test "measures timings" do
        end
      end
    end
    subclass = Class.new(test_case)

    assert test_case.serial_test?("measures timings")
    refute test_case.serial_test?("does not care")
    assert subclass.serial_test?("measures timings")
    refute nested.serial_test?("measures timings")
    assert_includes test_case.runnable_methods, "measures timings"
  end
end
