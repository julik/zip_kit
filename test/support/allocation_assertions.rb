require "allocation_stats" if RUBY_ENGINE == "ruby"

module AllocationAssertions
  def assert_allocates_under(max_objects, &blk)
    skip "allocation tracing not supported on #{RUBY_ENGINE}" unless RUBY_ENGINE == "ruby"

    trace = AllocationStats.trace(&blk)
    allocated = trace.new_allocations.size
    assert allocated < max_objects, -> {
      "expected under #{max_objects} objects to be allocated; got #{allocated}:\n\n" +
        trace.allocations(alias_paths: true).group_by(:sourcefile, :sourceline, :class).to_text
    }
  end
end
