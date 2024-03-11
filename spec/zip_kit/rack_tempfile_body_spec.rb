require "spec_helper"

# This is a deprecated class and will be removed in zip_kit 7.x
describe ZipKit::RackTempfileBody do
  it "outputs a Tempfile and adds it to 'rack.tempfiles'" do
    env = {}
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackTempfileBody.new(env, iterable)

    expect(env["rack.tempfiles"]).to be_kind_of(Array)

    tf_path = body.to_path

    first_tempfile = env["rack.tempfiles"][0]
    expect(tf_path).to eq(first_tempfile.path)

    first_tempfile.rewind
    expect(first_tempfile.read).to eq("foobarbaz")
  end

  it "outputs the data using #each" do
    env = {}
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackTempfileBody.new(env, iterable)

    readback = StringIO.new
    readback.binmode
    body.each { |chunk| readback << chunk }
    expect(readback.string).to eq("foobarbaz")
  end
end
