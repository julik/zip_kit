# Lets Minitest test cases be declared with their description as-is:
#
#   class StreamerTest < TestCase
#     test "raises an InvalidOutput if the given object does not support the methods" do
#       ...
#     end
#
#     context "#write_file" do
#       def setup
#         super
#         @out = StringIO.new
#       end
#
#       test "rolls back on error" do
#         ...
#       end
#     end
#   end
#
# The description is the method name, verbatim - there is no mangling into test_some_snake_case,
# so reports and the `-n` filter show "StreamerTest #write_file#rolls back on error".
module DescriptiveTests
  def declared_tests
    @declared_tests ||= []
  end

  def serial_tests
    @serial_tests ||= []
  end

  def serial_test?(name)
    return serial_tests.include?(name) if declared_tests.include?(name)
    superclass.respond_to?(:serial_test?) && superclass.serial_test?(name)
  end

  # Pass `parallel: false` for a test which measures timings: it then runs after the
  # parallel workers are done, with the machine to itself (see ParallelRun).
  def test(description, parallel: true, &blk)
    name = description.to_s
    raise ArgumentError, "test #{name.inspect} needs a block" unless blk
    raise ArgumentError, "test #{name.inspect} is already defined in #{self.name}" if declared_tests.include?(name)
    if method_defined?(name) || private_method_defined?(name)
      owner = instance_method(name).owner
      inherited_test = owner.respond_to?(:declared_tests) && owner.declared_tests.include?(name)
      raise ArgumentError, "test #{name.inspect} would override #{owner}##{name}, reword it" unless inherited_test
    end

    declared_tests << name
    serial_tests << name unless parallel
    define_method(name, &blk)
  end

  # Opens a nested test case. It inherits setup/teardown and helper methods from the enclosing
  # one and can add its own, but it does not re-run the tests of the enclosing test case.
  def context(description, &blk)
    parent_name = name
    Class.new(self) do
      @nested_context = true
      define_singleton_method(:name) { "#{parent_name} #{description}" }
      define_singleton_method(:to_s) { name }
      define_singleton_method(:inspect) { name }
      class_eval(&blk)
    end
  end
  alias_method :describe, :context

  def nested_context?
    @nested_context == true
  end

  def runnable_methods
    # A plain subclass gets the tests of its parent (same as Minitest does with test_ methods),
    # a context does not.
    names = if nested_context?
      declared_tests + instance_methods(false).map(&:to_s).grep(/^test_/)
    else
      inherited = superclass.respond_to?(:declared_tests) ? superclass.runnable_methods : []
      inherited | declared_tests | methods_matching(/^test_/)
    end

    # Always shuffled, whatever test_order says: tests here must not depend on the order they run in
    names.sort.shuffle(random: Random.new(Minitest.seed))
  end
end
