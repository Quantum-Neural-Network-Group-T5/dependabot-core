# frozen_string_literal: true

require "dependabot/bundler/update_checker"
require "dependabot/bundler/native_helpers"
require "dependabot/bundler/helpers"
require "dependabot/shared_helpers"

module Dependabot
  module Bundler
    class UpdateChecker < UpdateCheckers::Base
      class ConflictingDependencyResolver
        require_relative "shared_bundler_helpers"
        include SharedBundlerHelpers

        def initialize(dependency_files:, repo_contents_path:, credentials:)
          @dependency_files = dependency_files
          @repo_contents_path = repo_contents_path
          @credentials = credentials
        end

        # Finds any dependencies in the lockfile that have a subdependency on
        # the given dependency that does not satisfly the target_version.
        #
        # @param dependency [Dependabot::Dependency] the dependency to check
        # @param target_version [String] the version to check
        # @return [Array<Hash{String => String}]
        #   * name [String] the blocking dependencies name
        #   * version [String] the version of the blocking dependency
        #   * requirement [String] the requirement on the target_dependency
        def conflicting_dependencies(dependency:, target_version:)
          in_a_native_bundler_context(error_handling: false) do |tmp_dir|
            SharedHelpers.run_helper_subprocess(
              command: NativeHelpers.helper_path(bundler_version: bundler_version),
              function: "conflicting_dependencies",
              env: {
                "BUNDLER_VERSION" => bundler_version.tr("v", ""),
                "PATH" => ENV["PATH"],
                "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"]
              },
              unsetenv_others: true,
              args: {
                dir: tmp_dir,
                dependency_name: dependency.name,
                target_version: target_version,
                credentials: credentials,
                lockfile_name: lockfile.name,
                using_bundler2: using_bundler2?
              }
            )
          end
        end

        private

        def bundler_version
          @bundler_version ||= Helpers.bundler_version(lockfile)
        end
      end
    end
  end
end
