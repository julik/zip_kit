# frozen_string_literal: true

class ZipKit::Railtie < ::Rails::Railtie
  initializer "zip_kit.install_extensions" do |app|
    ActionController::Base.include(ZipKit::RailsStreaming)
  end
end
