# frozen_string_literal: true

module Dependabot
  module Bundler
    module Helpers
      def self.bundler_version(lockfile)
        return "v1" unless lockfile

        # return "v2" if lockfile.content.match?(/BUNDLED WITH\s+2/m)

        "v1"
      end
    end
  end
end
