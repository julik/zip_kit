require "test_helper"

class PathSetTest < TestCase
  def path_set
    @path_set ||= ZipKit::PathSet.new
  end

  test "allows adding multiple files" do
    assert_nothing_raised do
      path_set.add_file_path("foo.txt")
      path_set.add_file_path("bar.txt")
      path_set.add_file_path("baz.txt")
      path_set.add_directory_path("subdir")
    end

    ["foo.txt", "bar.txt", "baz.txt", "subdir"].each { |path| assert_includes path_set, path }
  end

  test "does not raise when a directory gets added twice" do
    assert_nothing_raised do
      path_set.add_directory_path("subdir")
      path_set.add_directory_path("subdir")
    end

    assert_includes path_set, "subdir"
  end

  test "raises when a file would clobber a directory" do
    path_set.add_directory_path("maybe-dir-maybe-file")
    assert_raises(ZipKit::PathSet::FileClobbersDirectory) do
      path_set.add_file_path("maybe-dir-maybe-file")
    end
  end

  test "raises when a directory would clobber a file" do
    path_set.add_file_path("maybe-dir-maybe-file")
    assert_raises(ZipKit::PathSet::DirectoryClobbersFile) do
      path_set.add_directory_path("maybe-dir-maybe-file")
    end
  end

  test "raises when a file would clobber a directory to create its implicit subtree" do
    path_set.add_file_path("a/b/c/d/e/f")
    assert_raises(ZipKit::PathSet::DirectoryClobbersFile) do
      path_set.add_file_path("a/b/c/d/e/f/g")
    end
  end

  test "raises when a directory would clobber a file to create its implicit subtree" do
    path_set.add_file_path("a/b/c/d/e/f")
    assert_raises(ZipKit::PathSet::DirectoryClobbersFile) do
      path_set.add_directory_path("a/b/c/d/e/f/g")
    end
  end

  describe "#include?" do
    test "answers both for specifically added items and for their path components" do
      path_set.add_file_path("dir1/dir2/file.doc")
      path_set.add_directory_path("another-dir/")

      assert_includes path_set, "dir1"
      assert_includes path_set, "dir1/dir2"
      assert_includes path_set, "dir1/dir2/file.doc"
      assert_includes path_set, "another-dir"

      refute_includes path_set, "dir2" # This is only included with its parent
      refute_includes path_set, "not-there" # Just not in this set
    end
  end

  describe "#clear" do
    test "deletes elements" do
      path_set.add_file_path("f")
      path_set.add_directory_path("d")

      assert_includes path_set, "d"
      assert_includes path_set, "f"

      path_set.clear

      refute_includes path_set, "d"
      refute_includes path_set, "f"
    end
  end
end
