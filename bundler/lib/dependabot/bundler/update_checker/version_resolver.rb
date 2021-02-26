# frozen_string_literal: true

require "excon"

require "dependabot/bundler/helpers"
require "dependabot/bundler/update_checker"
require "dependabot/bundler/file_updater/lockfile_updater"
require "dependabot/bundler/requirement"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module Bundler
    class UpdateChecker
      class VersionResolver
        require_relative "file_preparer"
        require_relative "latest_version_finder"
        require_relative "shared_bundler_helpers"
        include SharedBundlerHelpers

        def initialize(dependency:, unprepared_dependency_files:,
                       repo_contents_path: nil, credentials:, ignored_versions:,
                       raise_on_ignored: false,
                       replacement_git_pin: nil, remove_git_source: false,
                       unlock_requirement: true,
                       latest_allowable_version: nil)
          @dependency                  = dependency
          @unprepared_dependency_files = unprepared_dependency_files
          @credentials                 = credentials
          @repo_contents_path          = repo_contents_path
          @ignored_versions            = ignored_versions
          @raise_on_ignored            = raise_on_ignored
          @replacement_git_pin         = replacement_git_pin
          @remove_git_source           = remove_git_source
          @unlock_requirement          = unlock_requirement
          @latest_allowable_version    = latest_allowable_version
        end

        def latest_resolvable_version_details
          @latest_resolvable_version_details ||=
            fetch_latest_resolvable_version_details
        end

        private

        attr_reader :dependency, :unprepared_dependency_files,
                    :repo_contents_path, :credentials, :ignored_versions,
                    :replacement_git_pin, :latest_allowable_version

        def remove_git_source?
          @remove_git_source
        end

        def unlock_requirement?
          @unlock_requirement
        end

        def dependency_files
          @dependency_files ||=
            FilePreparer.new(
              dependency: dependency,
              dependency_files: unprepared_dependency_files,
              replacement_git_pin: replacement_git_pin,
              remove_git_source: remove_git_source?,
              unlock_requirement: unlock_requirement?,
              latest_allowable_version: latest_allowable_version
            ).prepared_dependency_files
        end

        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/MethodLength
        def fetch_latest_resolvable_version_details
          return latest_version_details unless gemfile

          SharedHelpers.with_git_configured(credentials: credentials) do
            # We do not want the helper to handle errors for us as there are
            # some errors we want to handle specifically ourselves, including
            # potentially retrying in the case of the Ruby version being locked
            in_a_native_bundler_context(error_handling: false) do |tmp_dir|
              details =  SharedHelpers.run_helper_subprocess(
                command: NativeHelpers.helper_path(bundler_version: bundler_version),
                function: "resolve_version",
                env: {
                  "BUNDLER_VERSION" => bundler_version.tr("v", ""),
                  "PATH" => ENV["PATH"],
                  "HOME" => ENV["HOME"],
                  "BUNDLE_GEMFILE" => File.join(NativeHelpers.native_helpers_root, "Gemfile")
                },
                unsetenv_others: true,
                args: {
                  dependency_name: dependency.name,
                  dependency_requirements: dependency.requirements,
                  gemfile_name: gemfile.name,
                  lockfile_name: lockfile&.name,
                  using_bundler2: using_bundler2?,
                  dir: tmp_dir,
                  credentials: credentials
                }
              )

              return latest_version_details if details == "latest"

              if details
                details.transform_keys!(&:to_sym)

                # If the old Gemfile index was used then it won't have checked
                # Ruby compatibility. Fix that by doing the check manually and
                # saying no update is possible if the Ruby version is a
                # mismatch
                return nil if ruby_version_incompatible?(details)

                details[:version] = Gem::Version.new(details[:version])
              end
              details
            end
          end
        rescue Dependabot::SharedHelpers::HelperSubprocessFailed => e
          return if error_due_to_restrictive_upper_bound?(e)
          return if circular_dependency_at_new_version?(e)

          # If we are unable to handle the error ourselves, pass it on to the
          # general bundler error handling.
          handle_bundler_errors(e) unless ruby_lock_error?(e)

          @gemspec_ruby_unlocked = true
          regenerate_dependency_files_without_ruby_lock && retry
        end
        # rubocop:enable Metrics/MethodLength
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/PerceivedComplexity

        def circular_dependency_at_new_version?(error)
          return false unless error.error_class.include?("CyclicDependencyError")

          error.message.include?("'#{dependency.name}'")
        end

        def error_due_to_restrictive_upper_bound?(error)
          # We see this when the dependency doesn't appear in the lockfile and
          # has an overly restrictive upper bound that we've added, either due
          # to an ignore condition or us missing that a pre-release is required
          # (as another dependency places a pre-release requirement on the dep)
          return false if dependency.appears_in_lockfile?

          error.message.include?("#{dependency.name} ")
        end

        def ruby_lock_error?(error)
          return false unless error.message.include?(" for gem \"ruby\0\"")
          return false if @gemspec_ruby_unlocked

          dependency_files.any? { |f| f.name.end_with?(".gemspec") }
        end

        def regenerate_dependency_files_without_ruby_lock
          @dependency_files =
            FilePreparer.new(
              dependency: dependency,
              dependency_files: unprepared_dependency_files,
              replacement_git_pin: replacement_git_pin,
              remove_git_source: remove_git_source?,
              unlock_requirement: unlock_requirement?,
              latest_allowable_version: latest_allowable_version,
              lock_ruby_version: false
            ).prepared_dependency_files
        end

        def latest_version_details
          @latest_version_details ||=
            LatestVersionFinder.new(
              dependency: dependency,
              dependency_files: dependency_files,
              repo_contents_path: repo_contents_path,
              credentials: credentials,
              ignored_versions: ignored_versions,
              raise_on_ignored: @raise_on_ignored,
              security_advisories: []
            ).latest_version_details
        end

        def ruby_version_incompatible?(details)
          # It's only the old index we have a problem with
          return false unless details[:fetcher] == "Bundler::Fetcher::Dependency"

          # If no Ruby version is specified, we don't have a problem
          return false unless details[:ruby_version]

          versions = Excon.get(
            "https://rubygems.org/api/v1/versions/#{dependency.name}.json",
            idempotent: true,
            **SharedHelpers.excon_defaults
          )

          # Give the benefit of the doubt if something goes wrong fetching
          # version details (could be that it's a private index, etc.)
          return false unless versions.status == 200

          ruby_requirement =
            JSON.parse(versions.body).
            find { |version| version["number"] == details[:version] }&.
            fetch("ruby_version", nil)

          # Give the benefit of the doubt if we can't find the version's
          # required Ruby version.
          return false unless ruby_requirement

          ruby_requirement = Gem::Requirement.new(ruby_requirement)
          current_ruby_version = Gem::Version.new(details[:ruby_version])

          !ruby_requirement.satisfied_by?(current_ruby_version)
        rescue JSON::ParserError, Excon::Error::Socket, Excon::Error::Timeout
          # Give the benefit of the doubt if something goes wrong fetching
          # version details (could be that it's a private index, etc.)
          false
        end

        def gemfile
          dependency_files.find { |f| f.name == "Gemfile" } ||
            dependency_files.find { |f| f.name == "gems.rb" }
        end

        def lockfile
          dependency_files.find { |f| f.name == "Gemfile.lock" } ||
            dependency_files.find { |f| f.name == "gems.locked" }
        end

        def using_bundler2?
          return unless lockfile

          lockfile.content.match?(/BUNDLED WITH\s+2/m)
        end

        def bundler_version
          @bundler_version ||= Helpers.bundler_version(lockfile)
        end
      end
    end
  end
end
