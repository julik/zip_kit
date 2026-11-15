# Tells whether the run time of some code grows as O(1), O(n) or O(n^2) with the size of its input.
# We time the code at a few sizes, fit a constant, a linear and a quadratic model to the timings,
# then take a second set of timings and see which model predicts them best.
#
# The method is lifted from the complexity_assert gem by Philippe Bourgau (MIT license,
# https://github.com/philou/complexity-assert), which only comes with RSpec matchers.
module ComplexityAssertions
  SIZES = [8, 10, 12, 80, 100, 120, 800, 1000, 1200]
  WARMUP_ROUNDS = 60
  ROUNDS = 10

  class ConstantModel
    def fit(timings)
      @average = timings.sum { |(_size, time)| time } / timings.size
    end

    def predict(_size)
      @average
    end

    def to_s
      "O(1)"
    end
  end

  class LinearModel
    def fit(timings)
      @slope, @intercept = ComplexityAssertions.linear_regression(timings)
    end

    def predict(size)
      @intercept + @slope * size
    end

    def to_s
      "O(n)"
    end
  end

  # Fits a line to the square roots of the timings, and squares it back
  class QuadraticModel
    def fit(timings)
      sqrt_slope, sqrt_intercept = ComplexityAssertions.linear_regression(timings.map { |(size, time)| [size, Math.sqrt(time)] })
      @quadratic = sqrt_slope * sqrt_slope
      @slope = 2 * sqrt_slope * sqrt_intercept
      @intercept = sqrt_intercept * sqrt_intercept
    end

    def predict(size)
      @intercept + @slope * size + @quadratic * size * size
    end

    def to_s
      "O(n^2)"
    end
  end

  # Returns the slope and the intercept of the least squares line through the [x, y] points
  def self.linear_regression(points)
    x_mean = points.sum { |(x, _y)| x }.to_f / points.size
    y_mean = points.sum { |(_x, y)| y }.to_f / points.size
    numerator = points.sum { |(x, y)| (x - x_mean) * (y - y_mean) }
    denominator = points.sum { |(x, _y)| (x - x_mean)**2 }
    slope = numerator / denominator
    [slope, y_mean - slope * x_mean]
  end

  # Returns [size, seconds] pairs, `rounds` of them per size
  def self.sample(rounds)
    SIZES.flat_map do |size|
      Array.new(rounds) do
        GC.disable
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield(size)
        [size, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      ensure
        GC.enable
      end
    end
  end

  # Returns "O(1)", "O(n)" or "O(n^2)" for a block which gets called with the input size
  def self.identify(&blk)
    sample(WARMUP_ROUNDS, &blk)
    classify(sample(ROUNDS, &blk), sample(ROUNDS, &blk))
  end

  # Fits the models to the first set of timings and picks the one which predicts the second set best
  def self.classify(fitting_timings, validation_timings)
    models = [ConstantModel.new, LinearModel.new, QuadraticModel.new]
    models.each { |model| model.fit(fitting_timings) }
    errors = models.map do |model|
      [model, Math.sqrt(validation_timings.sum { |(size, time)| (time - model.predict(size))**2 })]
    end

    # Models come in order of complexity cost. Favor the simpler one unless
    # a costlier one fits at least twice as well - this fights overfitting.
    best_model, best_error = errors.first
    errors.drop(1).each do |(model, error)|
      best_model, best_error = model, error if error < best_error / 2
    end
    best_model.to_s
  end

  # The block gets the input size and has to do an amount of work proportional to it
  def assert_linear_complexity(&blk)
    complexity = ComplexityAssertions.identify(&blk)
    assert_includes ["O(1)", "O(n)"], complexity, "expected a complexity equal or better than O(n)"
  end
end
