require "test_helper"

class UniquifyFilenameTest < TestCase
  test "returns the filename as is if it is not present in the check set" do
    check_set = Set.new
    assert_equal "file.txt", ZipKit::UniquifyFilename.call("file.txt", check_set)
    assert_predicate check_set, :empty?, "Should not have added anything to the check set"
  end

  test "deduplicates the filename if it is already contained in the set of unique names" do
    check_set = Set.new(["foo.txt"])
    assert_equal "foo (1).txt", ZipKit::UniquifyFilename.call("foo.txt", check_set)
  end

  test "deduplicates the filename and increments the counter as long as necessary to arrive at a unique one" do
    check_set = Set.new(["foo.txt", "foo (1).txt", "foo (2).txt"])
    assert_equal "foo (3).txt", ZipKit::UniquifyFilename.call("foo.txt", check_set)
  end

  test "when the filename extension is .gd and there is an extension in front of it, inserts the counter before that extension" do
    check_set = Set.new(["foo.data.gz"])
    assert_equal "foo (1).data.gz", ZipKit::UniquifyFilename.call("foo.data.gz", check_set)
  end
end
