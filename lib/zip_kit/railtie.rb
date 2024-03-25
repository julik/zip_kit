# frozen_string_literal: true

class ZipKit::Railtie < ::Rails::Railtie
  initializer "zip_kit.install_extensions" do |app|
    ActionController::Base.include(ZipKit::RailsStreaming)
    ActionController::Renderers.add :zip do |obj, options, &blk|
      warn "zip renderer"
      zip_kit_stream(**options, &blk)
    end
  end
end
