# frozen_string_literal: true

module Dependabot
  module Bundler
    module NativeHelpers
      def self.helper_path(bundler_version: "v1")
        "bundle exec ruby #{File.join(native_helpers_root, bundler_version, 'run.rb')}"
      end

      def self.native_helpers_root
        helpers_root = ENV["DEPENDABOT_NATIVE_HELPERS_PATH"]
        return File.join(helpers_root, "bundler") unless helpers_root.nil?

        File.join(__dir__, "../../../helpers")
      end
    end
  end
end
