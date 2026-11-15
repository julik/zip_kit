require "test_helper"

# This is a deprecated class and will be removed in zip_kit 7.x
class RackTempfileBodyTest < TestCase
  test "outputs a Tempfile and adds it to 'rack.tempfiles'" do
    env = {}
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackTempfileBody.new(env, iterable)

    assert_kind_of Array, env["rack.tempfiles"]

    tf_path = body.to_path

    first_tempfile = env["rack.tempfiles"][0]
    assert_equal first_tempfile.path, tf_path

    first_tempfile.rewind
    assert_equal "foobarbaz", first_tempfile.read
  end

  test "outputs the data using #each" do
    env = {}
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackTempfileBody.new(env, iterable)

    readback = StringIO.new
    readback.binmode
    body.each { |chunk| readback << chunk }
    assert_equal "foobarbaz", readback.string
  end
end
