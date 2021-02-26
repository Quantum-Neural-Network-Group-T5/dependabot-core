# frozen_string_literal: true

require "dependabot/shared_helpers"

module Dependabot
  module Bundler
    module NativeHelpers
      def self.run_bundler_subprocess(function:, args:, bundler_version:)
        bundler_env_version = bundler_version.tr("v", "")

        SharedHelpers.run_helper_subprocess(
          command: helper_path(bundler_version: bundler_version),
          function: function,
          args: args,
          # Kernel#spawn: clear environment variables except specified by env
          unsetenv_others: true,
          env: {
            # Bundler will pick the matching installed major version
            "BUNDLER_VERSION" => bundler_env_version,
            # Force bundler to load dependencies from an empty Gemfile so it
            # doesn't try to resolve dependencies from the customers
            # Gemfile/lockfile
            "BUNDLE_GEMFILE" => File.join(native_helpers_root, "Gemfile"),
            # Required to find the bundler and ruby bin
            "PATH" => ENV["PATH"],
            # Requried to create tmp directories in a writeable folder
            "HOME" => ENV["HOME"]
          }
        )
      end

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
