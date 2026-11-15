module RaiseAssertions
  # Minitest leaves this one out, since an exception fails the test anyway. It still
  # reads better when "does not raise" is the point of the test, and it gets counted
  # as an assertion. Returns what the block returns.
  def assert_nothing_raised(message = nil)
    result = yield
    pass
    result
  rescue Minitest::Assertion
    # A failed assertion or a skip inside of the block
    raise
  rescue => e
    prefix = message ? "#{message}.\n" : ""
    backtrace = Minitest.filter_backtrace(e.backtrace).join("\n    ")
    flunk "#{prefix}Expected nothing to be raised, but got #{e.class}: #{e.message}\n    #{backtrace}"
  end
end
