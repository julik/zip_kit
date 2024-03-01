require "spec_helper"

describe ZipKit do
  it "has a VERSION constant" do
    expect(ZipKit.constants).to include(:VERSION)
    expect(ZipKit::VERSION).to be_kind_of(String)
  end
end
