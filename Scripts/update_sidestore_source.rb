#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "tempfile"

require_relative "sidestore_source_common"

class SourceUpdateError < StandardError; end

class SideStoreSourceUpdater
  ROOT_KEYS = %w[
    name identifier sourceURL subtitle description iconURL website tintColor apps news
  ].freeze
  APP_STATIC_KEYS = %w[
    beta name bundleIdentifier developerName subtitle localizedDescription iconURL tintColor versions
  ].freeze
  VERSION_KEYS = %w[version date localizedDescription downloadURL size minOSVersion].freeze
  LEGACY_MAPPING = {
    "version" => "version",
    "versionDate" => "date",
    "versionDescription" => "localizedDescription",
    "downloadURL" => "downloadURL",
    "size" => "size"
  }.freeze

  def initialize(source_path:, metadata_path:, ipa_path:, tag:, date:, description:,
                 source_kind: "release")
    @source_path = File.expand_path(source_path)
    @metadata_path = File.expand_path(metadata_path)
    @ipa_path = File.expand_path(ipa_path)
    @tag = tag
    @date = date
    @description = description
    @profile = KOReaderSideStore.source_profile(source_kind)
  end

  def update!
    source = plain_object(KOReaderSideStore.load_json(@source_path, label: "source JSON"))
    metadata = KOReaderSideStore.load_release_metadata(@metadata_path)
    validate_inputs!(metadata)
    app = source_app(source)
    validate_existing_app!(app)
    expected = build_version(metadata)
    versions = app["versions"]

    existing_index = versions.index do |version|
      version.is_a?(Hash) && version["downloadURL"] == expected["downloadURL"]
    end
    if existing_index
      existing = versions[existing_index]
      # The workflow's calendar date can change on a later re-run. Keep the
      # already-published date instead of mutating history when every release
      # identity field still matches.
      immutable_keys = VERSION_KEYS - ["date"]
      mismatches = immutable_keys.reject { |key| existing[key] == expected[key] }
      assert(mismatches.empty?,
             "published version already exists with different immutable fields: #{mismatches.join(', ')}")
      assert_legacy_matches!(app, versions.first)
      return false
    end

    validate_newer_than_history!(expected, metadata, versions.first) unless versions.empty?
    versions.unshift(expected)
    sync_legacy_fields!(app, expected)
    write_atomically(source)
    true
  rescue KOReaderSideStore::Error => error
    raise SourceUpdateError, error.message
  end

  private

  def validate_inputs!(metadata)
    assert(File.file?(@ipa_path), "IPA file not found: #{@ipa_path}")
    assert(File.size(@ipa_path).positive?, "IPA file must not be empty")
    expected_tag = KOReaderSideStore.expected_release_tag(metadata, source_kind: @profile.kind)
    if @profile.kind == "release"
      assert(@tag == metadata["releaseTag"],
             "--tag must exactly match release metadata.releaseTag")
    else
      assert(@tag == expected_tag,
             "--tag must exactly match testing tag #{expected_tag.inspect} derived from release metadata")
    end
    KOReaderSideStore.parse_date(@date, "release date")
    assert(@description.is_a?(String) && !@description.strip.empty?,
           "release description must be a non-empty string")
    assert(@description == @description.strip,
           "release description must not have leading or trailing whitespace")
    assert(@description == metadata["localizedDescription"],
           "--description must exactly match release metadata.localizedDescription")
  end

  def source_app(source)
    assert(source.is_a?(Hash), "source JSON must contain an object")
    forbidden = find_forbidden_keys(source)
    assert(forbidden.empty?, "source contains forbidden PAL/source fields: #{forbidden.uniq.join(', ')}")
    KOReaderSideStore.validate_exact_keys(source, "source", ROOT_KEYS)
    assert(source["name"] == @profile.source_name, "source.name is unexpected")
    assert(source["identifier"] == @profile.source_identifier,
           "source.identifier is unexpected")
    assert(source["sourceURL"] == @profile.source_url, "source.sourceURL is unexpected")
    assert(source["iconURL"] == @profile.icon_url, "source.iconURL is unexpected")
    assert(source["website"] == KOReaderSideStore::WEBSITE_URL, "source.website is unexpected")
    assert(source["tintColor"] == KOReaderSideStore::TINT_COLOR, "source.tintColor is unexpected")
    assert(source["news"] == [], "source.news must be an empty array")
    KOReaderSideStore.require_nonempty_strings(source, "source", %w[subtitle description])
    apps = source["apps"]
    assert(apps.is_a?(Array) && apps.length == 1,
           "source.apps must contain exactly one app")
    app = apps.first
    assert(app.is_a?(Hash), "source.apps[0] must be an object")
    versions = app["versions"]
    assert(versions.is_a?(Array), "source app versions must be an array")
    expected_app_keys = APP_STATIC_KEYS + (versions.empty? ? [] : LEGACY_MAPPING.keys)
    KOReaderSideStore.validate_exact_keys(app, "source.apps[0]", expected_app_keys)
    assert(app["beta"] == @profile.app_beta,
           "source app beta is unexpected")
    assert(app["name"] == @profile.app_name, "source app name is unexpected")
    assert(app["bundleIdentifier"] == KOReaderSideStore::BUNDLE_IDENTIFIER,
           "source app bundleIdentifier is unexpected")
    assert(app["developerName"] == KOReaderSideStore::DEVELOPER_NAME,
           "source app developerName is unexpected")
    assert(app["iconURL"] == @profile.icon_url, "source app iconURL is unexpected")
    assert(app["tintColor"] == KOReaderSideStore::TINT_COLOR,
           "source app tintColor is unexpected")
    KOReaderSideStore.require_nonempty_strings(
      app, "source.apps[0]", %w[subtitle localizedDescription]
    )
    app
  end

  def validate_existing_app!(app)
    versions = app["versions"]
    assert(versions.is_a?(Array), "source app versions must be an array")
    if versions.empty?
      unexpected_legacy = LEGACY_MAPPING.keys & app.keys
      assert(unexpected_legacy.empty?,
             "empty source template must not contain legacy release fields")
      return
    end

    parsed = versions.each_with_index.map do |version, index|
      path = "source.apps[0].versions[#{index}]"
      KOReaderSideStore.validate_exact_keys(version, path, VERSION_KEYS)
      semantic = KOReaderSideStore.parse_version(version["version"], "#{path}.version")
      release = KOReaderSideStore.parse_release_url(
        version["downloadURL"], "#{path}.downloadURL", source_kind: @profile.kind
      )
      assert(version["version"] == release[:version_string],
             "#{path} version and release tag disagree")
      KOReaderSideStore.parse_date(version["date"], "#{path}.date")
      assert(version["localizedDescription"].is_a?(String) && !version["localizedDescription"].strip.empty?,
             "#{path}.localizedDescription must be non-empty")
      assert(version["localizedDescription"] == version["localizedDescription"].strip,
             "#{path}.localizedDescription must not have surrounding whitespace")
      assert(version["size"].is_a?(Integer) && version["size"].positive?,
             "#{path}.size must be a positive integer")
      assert(version["minOSVersion"] == KOReaderSideStore::MINIMUM_OS_VERSION,
             "#{path}.minOSVersion is unexpected")
      { semantic: semantic, build: release[:build], date: Date.iso8601(version["date"]) }
    end
    parsed.each_cons(2) do |newer, older|
      assert((newer[:semantic] <=> older[:semantic]).positive?,
             "existing source versions are not strictly descending")
      assert(newer[:build] > older[:build],
             "existing source builds are not strictly descending")
      assert(newer[:date] >= older[:date],
             "existing source dates are not newest first")
    end
    assert_legacy_matches!(app, versions.first)
  end

  def build_version(metadata)
    {
      "version" => metadata["marketingVersion"],
      "date" => @date,
      "localizedDescription" => metadata["localizedDescription"],
      "downloadURL" => KOReaderSideStore.release_url(@tag, source_kind: @profile.kind),
      "size" => File.size(@ipa_path),
      "minOSVersion" => KOReaderSideStore::MINIMUM_OS_VERSION
    }
  end

  def validate_newer_than_history!(expected, metadata, latest)
    latest_semantic = KOReaderSideStore.parse_version(latest["version"], "latest source version")
    latest_release = KOReaderSideStore.parse_release_url(
      latest["downloadURL"], "latest source downloadURL", source_kind: @profile.kind
    )
    new_semantic = metadata["parsedMarketingVersion"]
    assert((new_semantic <=> latest_semantic).positive?,
           "new marketingVersion must be strictly greater than the latest published version")
    assert(metadata["parsedBuildVersion"] > latest_release[:build],
           "new buildVersion must be greater than every published build")
    new_date = KOReaderSideStore.parse_date(expected["date"], "new release date")
    old_date = KOReaderSideStore.parse_date(latest["date"], "latest source date")
    assert(new_date >= old_date, "new release date must not be older than the latest published date")
  end

  def assert_legacy_matches!(app, latest)
    missing = LEGACY_MAPPING.keys - app.keys
    assert(missing.empty?, "published source app is missing legacy fields: #{missing.join(', ')}")
    mismatches = LEGACY_MAPPING.reject { |legacy, version| app[legacy] == latest[version] }.keys
    assert(mismatches.empty?,
           "published source app legacy fields disagree with versions[0]: #{mismatches.join(', ')}")
  end

  def sync_legacy_fields!(app, version)
    LEGACY_MAPPING.each { |legacy, version_key| app[legacy] = version[version_key] }
  end

  def find_forbidden_keys(value)
    case value
    when Hash
      (value.keys & KOReaderSideStore::FORBIDDEN_KEYS) + value.values.flat_map { |child| find_forbidden_keys(child) }
    when Array
      value.flat_map { |child| find_forbidden_keys(child) }
    else
      []
    end
  end

  def plain_object(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), result| result[key] = plain_object(child) }
    when Array
      value.map { |child| plain_object(child) }
    else
      value
    end
  end

  def write_atomically(source)
    directory = File.dirname(@source_path)
    mode = File.stat(@source_path).mode
    temporary = Tempfile.new([".sidestore-source", ".json"], directory)
    temporary.binmode
    temporary.write(JSON.pretty_generate(source))
    temporary.write("\n")
    temporary.flush
    temporary.fsync
    temporary.chmod(mode)
    temporary.close
    File.rename(temporary.path, @source_path)
  ensure
    temporary&.close!
  end

  def assert(condition, message)
    raise SourceUpdateError, message unless condition
  end
end

if $PROGRAM_NAME == __FILE__
  repository_root = File.expand_path("..", __dir__)
  options = {
    source_path: File.join(repository_root, "sidestore-source.json"),
    metadata_path: File.join(repository_root, "platform", "ios", "release.json"),
    source_kind: "release"
  }

  parser = OptionParser.new do |opts|
    opts.banner =
      "Usage: #{File.basename($PROGRAM_NAME)} --ipa PATH --tag TAG --date DATE --description TEXT"
    opts.on("--source PATH", "Source JSON (default: repository sidestore-source.json)") do |path|
      options[:source_path] = path
    end
    opts.on("--metadata PATH", "Release metadata JSON (default: platform/ios/release.json)") do |path|
      options[:metadata_path] = path
    end
    opts.on("--source-kind KIND", KOReaderSideStore::SOURCE_KINDS,
            "Source profile: release or testing (default: release)") do |kind|
      options[:source_kind] = kind
    end
    opts.on("--ipa PATH", "Published IPA whose byte size will be recorded") do |path|
      options[:ipa_path] = path
    end
    opts.on("--tag TAG", "Exact GitHub Release tag for the selected source profile") do |tag|
      options[:tag] = tag
    end
    opts.on("--date DATE", "Published date in YYYY-MM-DD format") do |date|
      options[:date] = date
    end
    opts.on("--description TEXT", "Localized release description") do |description|
      options[:description] = description
    end
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
    %i[ipa_path tag date description].each do |key|
      option = key == :ipa_path ? "ipa" : key.to_s.tr("_", "-")
      raise OptionParser::MissingArgument, "--#{option}" unless options[key]
    end
    changed = SideStoreSourceUpdater.new(**options).update!
    puts changed ? "SideStore/LiveContainer source updated: #{File.expand_path(options[:source_path])}" :
      "SideStore/LiveContainer source already contains this release"
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue SourceUpdateError => error
    warn "SideStore/LiveContainer source update failed: #{error.message}"
    exit 1
  end
end
