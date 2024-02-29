# frozen_string_literal: true

require_relative "../lib/zip_kit"

# Any writable object can be used as a destination for the Streamer.
# For example, you can write to an S3 bucket. Newer versions of the S3 SDK
# support a method called `upload_stream` which allows streaming uploads. The
# SDK will split your streamed bytes into appropriately-sized multipart upload
# parts and PUT them onto S3.
bucket = Aws::S3::Bucket.new("mybucket")
obj = bucket.object("big.zip")
obj.upload_stream do |write_stream|
  ZipKit::Streamer.open(write_stream) do |zip|
    zip.write_file("large.csv") do |sink|
      CSV(sink) do |csv|
        csv << ["Line", "Item"]
        20_000.times do |n|
          csv << [n, "Item number #{n}"]
        end
      end
    end
  end
end
