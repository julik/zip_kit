# frozen_string_literal: true

class ZipKit::Railtie < ::Rails::Railtie
  initializer "zip_kit.install_extensions" do |app|
    ActiveSupport.on_load(:action_controller) do
      include(ZipKit::RailsStreaming)
    end
  end
end
