require "test_helper"

class ComplexityAssertionsTest < TestCase
  # Makes the timings a run would produce if it took `seconds_for.call(size)`, give or take 5%
  def timings(rng, &seconds_for)
    ComplexityAssertions::SIZES.flat_map do |size|
      Array.new(ComplexityAssertions::ROUNDS) { [size, seconds_for.call(size) * rng.rand(0.95..1.05)] }
    end
  end

  def classify(&seconds_for)
    rng = Random.new(Minitest.seed)
    ComplexityAssertions.classify(timings(rng, &seconds_for), timings(rng, &seconds_for))
  end

  test "fits a line through points" do
    slope, intercept = ComplexityAssertions.linear_regression([[1, 5], [2, 7], [3, 9], [10, 23]])
    assert_in_delta 2.0, slope
    assert_in_delta 3.0, intercept
  end

  test "recognizes timings which do not depend on the size as O(1)" do
    assert_equal "O(1)", classify { |_size| 0.002 }
  end

  test "recognizes timings which grow with the size as O(n)" do
    assert_equal "O(n)", classify { |size| 0.0001 + 0.00001 * size }
  end

  test "recognizes timings which grow with the square of the size as O(n^2)" do
    assert_equal "O(n^2)", classify { |size| 0.0001 + 0.00001 * size + 0.0000002 * size * size }
  end

  test "assert_linear_complexity passes for O(1) and O(n) and fails for O(n^2)" do
    ComplexityAssertions.stub(:identify, "O(1)") { assert_linear_complexity { |_size| } }
    ComplexityAssertions.stub(:identify, "O(n)") { assert_linear_complexity { |_size| } }

    error = assert_raises(Minitest::Assertion) do
      ComplexityAssertions.stub(:identify, "O(n^2)") { assert_linear_complexity { |_size| } }
    end
    assert_match(/O\(n\^2\)/, error.message)
  end

  test "samples the block a number of times for every size" do
    sizes = []
    timings = ComplexityAssertions.sample(2) { |size| sizes << size }
    assert_equal ComplexityAssertions::SIZES.flat_map { |size| [size, size] }, sizes
    assert_equal sizes, timings.map(&:first)
    assert timings.all? { |(_size, seconds)| seconds >= 0 }
  end
end
