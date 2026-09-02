#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"
require "uri"

module KOReaderSideStore
  REPOSITORY = "Minaduki-Shigure/koreader-ios"
  ASSET_NAME = "KOReader-Strict-Offline-SideStore.ipa"

  WEBSITE_URL = "https://github.com/#{REPOSITORY}"
  TINT_COLOR = "#00AFA7"

  BUNDLE_IDENTIFIER = "rocks.koreader.ios"
  DEVELOPER_NAME = "KOReader contributors and Minaduki-Shigure"
  MINIMUM_OS_VERSION = "14.0"
  RELEASE_CHANNELS = %w[beta stable].freeze

  SourceProfile = Struct.new(
    :kind,
    :source_branch,
    :source_name,
    :source_identifier,
    :app_name,
    :app_beta,
    :tag_prefix,
    keyword_init: true
  ) do
    def source_url
      "https://raw.githubusercontent.com/#{KOReaderSideStore::REPOSITORY}/refs/heads/" \
        "#{source_branch}/sidestore-source.json"
    end

    def icon_url
      "https://raw.githubusercontent.com/#{KOReaderSideStore::REPOSITORY}/refs/heads/" \
        "#{source_branch}/platform/ios/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
    end

    def release_tag(version, build)
      "#{tag_prefix}#{version}-b#{build}"
    end

    def tag_format
      "#{tag_prefix}X.Y.Z-bN"
    end
  end

  RELEASE_PROFILE = SourceProfile.new(
    kind: "release",
    source_branch: "ios-release",
    source_name: "KOReader iOS Strict Offline",
    source_identifier: "io.github.minaduki-shigure.koreader-ios.source",
    app_name: "KOReader",
    app_beta: false,
    tag_prefix: "ios-v"
  ).freeze
  TESTING_PROFILE = SourceProfile.new(
    kind: "testing",
    source_branch: "ios-testing",
    source_name: "KOReader iOS Strict Offline Testing",
    source_identifier: "io.github.minaduki-shigure.koreader-ios.testing-source",
    app_name: "KOReader Testing",
    app_beta: false,
    tag_prefix: "ios-test-v"
  ).freeze
  SOURCE_PROFILES = {
    RELEASE_PROFILE.kind => RELEASE_PROFILE,
    TESTING_PROFILE.kind => TESTING_PROFILE
  }.freeze
  SOURCE_KINDS = SOURCE_PROFILES.keys.freeze

  # Backwards-compatible aliases for the canonical release source.
  SOURCE_BRANCH = RELEASE_PROFILE.source_branch
  SOURCE_NAME = RELEASE_PROFILE.source_name
  SOURCE_IDENTIFIER = RELEASE_PROFILE.source_identifier
  SOURCE_URL = RELEASE_PROFILE.source_url
  ICON_URL = RELEASE_PROFILE.icon_url
  APP_NAME = RELEASE_PROFILE.app_name
  APP_BETA = RELEASE_PROFILE.app_beta

  FORBIDDEN_KEYS = %w[marketplaceID Build build buildVersion buildNumber sha256].freeze
  METADATA_KEYS = %w[
    marketingVersion buildVersion releaseTag upstreamTag channel localizedDescription
  ].freeze

  class Error < StandardError; end

  class StrictJSONObject < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate JSON key: #{key}" if key?(key)

      super
    end
  end

  module_function

  def source_profile(kind = "release")
    profile = SOURCE_PROFILES[kind.to_s]
    assert(profile, "source kind must be one of: #{SOURCE_KINDS.join(', ')}")
    profile
  end

  def expected_release_tag(metadata, source_kind: "release")
    profile = source_profile(source_kind)
    profile.release_tag(metadata.fetch("marketingVersion"), metadata.fetch("buildVersion"))
  end

  def load_json(path, label: path)
    object = JSON.parse(
      read_utf8(path),
      object_class: StrictJSONObject,
      allow_duplicate_key: false
    )
    assert(object.is_a?(Hash), "#{label} must contain a JSON object")
    object
  rescue JSON::ParserError => error
    message = error.message.match?(/duplicate (?:JSON )?key/i) ? "duplicate JSON key" : error.message
    raise Error, "invalid #{label}: #{message}"
  end

  def load_release_metadata(path)
    metadata = load_json(path, label: "release metadata")
    validate_exact_keys(metadata, "release metadata", METADATA_KEYS)
    require_nonempty_strings(metadata, "release metadata", METADATA_KEYS)

    marketing = parse_version(metadata["marketingVersion"], "release metadata.marketingVersion")
    upstream_match = metadata["upstreamTag"].match(/\Av\d+\.\d+(?:\.\d+)?\z/)
    assert(upstream_match, "release metadata.upstreamTag must use vX.Y or vX.Y.Z format")

    build = parse_build(metadata["buildVersion"], "release metadata.buildVersion")
    expected_tag = "ios-v#{metadata['marketingVersion']}-b#{metadata['buildVersion']}"
    assert(metadata["releaseTag"] == expected_tag,
           "release metadata.releaseTag must be #{expected_tag.inspect}")
    assert(RELEASE_CHANNELS.include?(metadata["channel"]),
           "release metadata.channel must be beta or stable")

    metadata.merge("parsedMarketingVersion" => marketing, "parsedBuildVersion" => build)
  end

  def release_url(tag, source_kind: "release")
    source_profile(source_kind)
    "https://github.com/#{REPOSITORY}/releases/download/#{tag}/#{ASSET_NAME}"
  end

  def parse_release_url(value, path, source_kind: "release")
    profile = source_profile(source_kind)
    uri = validate_https_url(value, path)
    assert(uri.host == "github.com", "#{path} must be hosted on github.com")
    assert(uri.query.nil? && uri.fragment.nil?, "#{path} must not contain a query or fragment")

    segments = uri.path.split("/", -1)
    prefix = ["", *REPOSITORY.split("/"), "releases", "download"]
    assert(segments.first(prefix.length) == prefix,
           "#{path} must point to this repository's GitHub Release")
    assert(segments.length == prefix.length + 2,
           "#{path} has an unexpected release asset path")
    assert(segments[-1] == ASSET_NAME, "#{path} asset must be #{ASSET_NAME}")

    tag_pattern = /\A#{Regexp.escape(profile.tag_prefix)}(\d+\.\d+\.\d+)-b([1-9]\d*)\z/
    tag_match = segments[-2].match(tag_pattern)
    assert(tag_match, "#{path} tag must use #{profile.tag_format} format")
    assert(value == release_url(segments[-2], source_kind: profile.kind),
           "#{path} must use the exact GitHub Release asset URL")
    {
      tag: segments[-2],
      version_string: tag_match[1],
      version: parse_version(tag_match[1], "#{path} tag version"),
      build: parse_build(tag_match[2], "#{path} tag build")
    }
  end

  def parse_version(value, path)
    assert(value.is_a?(String) && value.match?(/\A\d+\.\d+\.\d+\z/),
           "#{path} must use X.Y.Z format")
    value.split(".").map(&:to_i)
  end

  def parse_build(value, path)
    assert(value.is_a?(String) && value.match?(/\A[1-9]\d*\z/),
           "#{path} must be a positive decimal integer string")
    value.to_i
  end

  def parse_date(value, path)
    assert(value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/),
           "#{path} must use YYYY-MM-DD format")
    date = Date.iso8601(value)
    assert(date.iso8601 == value, "#{path} must be a canonical calendar date")
    date
  rescue Date::Error
    raise Error, "#{path} is not a valid calendar date"
  end

  def validate_https_url(value, path, expected: nil)
    assert(value.is_a?(String) && !value.empty?, "#{path} must be a non-empty URL string")
    uri = URI.parse(value)
    assert(uri.scheme == "https" && !uri.host.nil?, "#{path} must be an absolute HTTPS URL")
    assert(uri.userinfo.nil?, "#{path} must not contain user information")
    assert(value == expected, "#{path} must be #{expected.inspect}") if expected
    uri
  rescue URI::InvalidURIError => error
    raise Error, "#{path} is not a valid URL: #{error.message}"
  end

  def validate_exact_keys(object, path, expected)
    assert(object.is_a?(Hash), "#{path} must be an object")
    missing = expected - object.keys
    unknown = object.keys - expected
    assert(missing.empty?, "#{path} is missing keys: #{missing.join(', ')}")
    assert(unknown.empty?, "#{path} has unsupported keys: #{unknown.join(', ')}")
  end

  def require_nonempty_strings(object, path, keys)
    keys.each do |key|
      value = object[key]
      assert(value.is_a?(String) && !value.strip.empty?,
             "#{path}.#{key} must be a non-empty string")
      assert(value == value.strip,
             "#{path}.#{key} must not have leading or trailing whitespace")
    end
  end

  def read_utf8(path)
    text = File.binread(path).force_encoding(Encoding::UTF_8)
    assert(text.valid_encoding?, "#{path} is not valid UTF-8")
    text
  rescue Errno::ENOENT
    raise Error, "file not found: #{path}"
  rescue Errno::EACCES
    raise Error, "file is not readable: #{path}"
  end

  def assert(condition, message)
    raise Error, message unless condition
  end
end
