require "test_helper"

class ZipKitTest < TestCase
  test "has a VERSION constant" do
    assert_includes ZipKit.constants, :VERSION
    assert_kind_of String, ZipKit::VERSION
  end
end
