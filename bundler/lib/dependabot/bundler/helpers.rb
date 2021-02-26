# frozen_string_literal: true

module Dependabot
  module Bundler
    module Helpers
      # TODO: Add support for bundler v2
      # return "v2" if lockfile.content.match?(/BUNDLED WITH\s+2/m)
      def self.bundler_version(_lockfile)
        "v1"
      end
    end
  end
end
