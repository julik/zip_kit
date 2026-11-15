# complexity_assert only ships RSpec matchers (and requires rspec/expectations when loaded whole),
# so load its models piecemeal and do the identification here.
require "complexity_assert/complexity_validator"
require "complexity_assert/constant_complexity_model"
require "complexity_assert/linear_complexity_model"
require "complexity_assert/quadratic_complexity_model"
require "complexity_assert/sampler"
require "complexity_assert/simple_linear_regression"
require "complexity_assert/warmup_sampler"

module ComplexityAssertions
  # `algo` responds to `generate_args(size)` and `run(*args)`, same as for complexity_assert
  def assert_linear_complexity(algo)
    complexity = identify_complexity(algo)
    assert_includes ["O(1)", "O(n)"], complexity, "expected #{algo} to have a complexity equal or better than O(n)"
  end

  private

  def identify_complexity(algo)
    sampler = ComplexityAssert::WarmupSampler.new(ComplexityAssert::Sampler.new(algo), 60)
    timings = sampler.run([8, 10, 12, 80, 100, 120, 800, 1000, 1200], 10)
    models = [
      ComplexityAssert::ConstantComplexityModel.new,
      ComplexityAssert::LinearComplexityModel.new,
      ComplexityAssert::QuadraticComplexityModel.new
    ]
    models.each { |model| model.analyze(timings) }

    # Models come in order of complexity cost. Favor the simpler one unless
    # a costlier one fits at least twice as well - this fights overfitting.
    rmses = ComplexityAssert::ComplexityValidator.new(sampler, models).rmses
    best = rmses.first
    rmses.drop(1).each do |candidate|
      best = candidate if candidate[1] < best[1] / 2
    end
    best[0]
  end
end
