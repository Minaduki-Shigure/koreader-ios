#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "optparse"

require_relative "sidestore_source_common"

class SideStoreSourceValidator
  ROOT_KEYS = %w[
    name identifier sourceURL subtitle description iconURL website tintColor apps news
  ].freeze
  APP_STATIC_KEYS = %w[
    beta name bundleIdentifier developerName subtitle localizedDescription iconURL tintColor versions
  ].freeze
  LEGACY_KEYS = %w[version versionDate versionDescription downloadURL size].freeze
  VERSION_KEYS = %w[
    version date localizedDescription downloadURL size minOSVersion
  ].freeze

  def initialize(source_path:, metadata_path:, ipa_path: nil, sha256_path: nil, tag: nil,
                 allow_empty_template: false, history_only: false, source_kind: "release")
    @source_path = File.expand_path(source_path)
    @metadata_path = File.expand_path(metadata_path)
    @ipa_path = ipa_path && File.expand_path(ipa_path)
    @sha256_path = sha256_path && File.expand_path(sha256_path)
    @tag = tag
    @allow_empty_template = allow_empty_template
    @history_only = history_only
    @profile = KOReaderSideStore.source_profile(source_kind)
  end

  def validate!
    assert(!@sha256_path || @ipa_path, "--sha256-file requires --ipa")
    assert(!@history_only || !@ipa_path,
           "--history-only cannot be combined with --ipa")
    assert(!@history_only || !@tag,
           "--history-only cannot be combined with --tag")
    metadata = KOReaderSideStore.load_release_metadata(@metadata_path)
    if @tag
      expected_tag = KOReaderSideStore.expected_release_tag(metadata, source_kind: @profile.kind)
      message = if @profile.kind == "release"
                  "--tag must exactly match release metadata.releaseTag"
                else
                  "--tag must exactly match testing tag #{expected_tag.inspect} derived from release metadata"
                end
      assert(@tag == expected_tag, message)
    end
    source = KOReaderSideStore.load_json(@source_path, label: "source JSON")

    reject_forbidden_keys(source)
    latest = validate_source(source, metadata)
    validate_ipa(latest) if @ipa_path
    true
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  private

  def validate_source(source, metadata)
    validate_exact_keys(source, "source", ROOT_KEYS)
    assert(source["name"] == @profile.source_name,
           "source.name must be #{@profile.source_name.inspect}")
    assert(source["identifier"] == @profile.source_identifier,
           "source.identifier must be #{@profile.source_identifier.inspect}")
    require_nonempty_strings(source, "source", %w[subtitle description])
    validate_url(source["sourceURL"], "source.sourceURL", @profile.source_url)
    validate_url(source["iconURL"], "source.iconURL", @profile.icon_url)
    validate_url(source["website"], "source.website", KOReaderSideStore::WEBSITE_URL)
    assert(source["tintColor"] == KOReaderSideStore::TINT_COLOR,
           "source.tintColor must be #{KOReaderSideStore::TINT_COLOR.inspect}")
    assert(source["news"] == [], "source.news must be an empty array")

    apps = source["apps"]
    assert(apps.is_a?(Array) && apps.length == 1,
           "source.apps must contain exactly one app")
    validate_app(apps.first, metadata)
  end

  def validate_app(app, metadata)
    assert(app.is_a?(Hash), "source.apps[0] must be an object")
    versions = app["versions"]
    assert(versions.is_a?(Array), "source.apps[0].versions must be an array")
    expected_keys = APP_STATIC_KEYS + (versions.empty? ? [] : LEGACY_KEYS)
    validate_exact_keys(app, "source.apps[0]", expected_keys)

    assert(app["beta"] == @profile.app_beta,
           "source.apps[0].beta must be #{@profile.app_beta}")
    assert(app["name"] == @profile.app_name,
           "source.apps[0].name must be #{@profile.app_name.inspect}")
    assert(app["bundleIdentifier"] == KOReaderSideStore::BUNDLE_IDENTIFIER,
           "source.apps[0].bundleIdentifier must be #{KOReaderSideStore::BUNDLE_IDENTIFIER.inspect}")
    assert(app["developerName"] == KOReaderSideStore::DEVELOPER_NAME,
           "source.apps[0].developerName must be #{KOReaderSideStore::DEVELOPER_NAME.inspect}")
    require_nonempty_strings(app, "source.apps[0]", %w[subtitle localizedDescription])
    validate_url(app["iconURL"], "source.apps[0].iconURL", @profile.icon_url)
    assert(app["tintColor"] == KOReaderSideStore::TINT_COLOR,
           "source.apps[0].tintColor must be #{KOReaderSideStore::TINT_COLOR.inspect}")

    if versions.empty?
      assert(@allow_empty_template,
             "source app versions must not be empty (use --allow-empty-template only before the first release)")
      return nil
    end

    parsed = versions.each_with_index.map do |version, index|
      validate_version(version, index).merge(source: version)
    end
    validate_history_order(parsed)

    latest = versions.first
    validate_legacy_fields(app, latest)
    return latest if @history_only

    expected_tag = @tag || KOReaderSideStore.expected_release_tag(metadata, source_kind: @profile.kind)
    target = parsed.find { |candidate| candidate[:tag] == expected_tag }
    assert(target, "source does not contain release metadata tag #{expected_tag.inspect}")
    assert(target[:source]["version"] == metadata["marketingVersion"],
           "target source version must match release metadata.marketingVersion")
    assert(target[:source]["localizedDescription"] == metadata["localizedDescription"],
           "target source description must match release metadata.localizedDescription")
    assert(target[:build] == metadata["parsedBuildVersion"],
           "target source release tag build must match release metadata.buildVersion")
    target[:source]
  end

  def validate_version(version, index)
    path = "source.apps[0].versions[#{index}]"
    validate_exact_keys(version, path, VERSION_KEYS)
    require_nonempty_strings(version, path, %w[version localizedDescription])
    semantic = parse_version(version["version"], "#{path}.version")
    date = parse_date(version["date"], "#{path}.date")
    assert(version["size"].is_a?(Integer) && version["size"].positive?,
           "#{path}.size must be a positive integer byte count")
    assert(version["minOSVersion"] == KOReaderSideStore::MINIMUM_OS_VERSION,
           "#{path}.minOSVersion must be #{KOReaderSideStore::MINIMUM_OS_VERSION.inspect}")

    release = KOReaderSideStore.parse_release_url(
      version["downloadURL"], "#{path}.downloadURL", source_kind: @profile.kind
    )
    assert(version["version"] == release[:version_string],
           "#{path}.version must identify the same version as its release tag")
    { semantic: semantic, build: release[:build], date: date, tag: release[:tag] }
  end

  def validate_history_order(parsed)
    parsed.each_cons(2) do |newer, older|
      assert((newer[:semantic] <=> older[:semantic]).positive?,
             "source versions must be strictly descending by marketing version")
      assert(newer[:build] > older[:build],
             "source release builds must be strictly descending")
      assert(newer[:date] >= older[:date],
             "source versions must be ordered newest first by date")
    end
  end

  def validate_legacy_fields(app, latest)
    expected = {
      "version" => latest["version"],
      "versionDate" => latest["date"],
      "versionDescription" => latest["localizedDescription"],
      "downloadURL" => latest["downloadURL"],
      "size" => latest["size"]
    }
    mismatches = LEGACY_KEYS.reject { |key| app[key] == expected[key] }
    assert(mismatches.empty?,
           "source app legacy fields must match versions[0]: #{mismatches.join(', ')}")
  end

  def validate_ipa(latest)
    assert(latest, "cannot validate an IPA against an empty source template")
    assert(File.file?(@ipa_path), "IPA file not found: #{@ipa_path}")
    actual_size = File.size(@ipa_path)
    assert(actual_size == latest["size"],
           "IPA size mismatch: source has #{latest['size']}, file has #{actual_size}")
    return unless @sha256_path

    expected_sha256 = read_sha256_file(@sha256_path)
    actual_sha256 = Digest::SHA256.file(@ipa_path).hexdigest
    assert(actual_sha256 == expected_sha256,
           "IPA SHA-256 mismatch: checksum file has #{expected_sha256}, file has #{actual_sha256}")
  end

  def read_sha256_file(path)
    text = KOReaderSideStore.read_utf8(path).strip
    match = text.match(/\A([0-9a-f]{64})(?:[ \t]+\*?(.+))?\z/)
    assert(match, "SHA-256 file must contain one lowercase SHA-256 digest")
    if match[2]
      checksum_name = File.basename(match[2].strip)
      assert(checksum_name == File.basename(@ipa_path),
             "SHA-256 filename must match the IPA filename")
    end
    match[1]
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def reject_forbidden_keys(value, path = "source")
    case value
    when Hash
      forbidden = value.keys & KOReaderSideStore::FORBIDDEN_KEYS
      assert(forbidden.empty?,
             "#{path} contains forbidden PAL/source fields: #{forbidden.join(', ')}")
      value.each { |key, child| reject_forbidden_keys(child, "#{path}.#{key}") }
    when Array
      value.each_with_index { |child, index| reject_forbidden_keys(child, "#{path}[#{index}]") }
    end
  end

  def validate_exact_keys(*arguments)
    KOReaderSideStore.validate_exact_keys(*arguments)
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def require_nonempty_strings(*arguments)
    KOReaderSideStore.require_nonempty_strings(*arguments)
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def validate_url(value, path, expected)
    KOReaderSideStore.validate_https_url(value, path, expected: expected)
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def parse_version(*arguments)
    KOReaderSideStore.parse_version(*arguments)
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def parse_date(*arguments)
    KOReaderSideStore.parse_date(*arguments)
  rescue KOReaderSideStore::Error => error
    raise ValidationError, error.message
  end

  def assert(condition, message)
    raise ValidationError, message unless condition
  end
end

class ValidationError < StandardError; end

if $PROGRAM_NAME == __FILE__
  repository_root = File.expand_path("..", __dir__)
  options = {
    source_path: File.join(repository_root, "sidestore-source.json"),
    metadata_path: File.join(repository_root, "platform", "ios", "release.json"),
    ipa_path: nil,
    sha256_path: nil,
    tag: nil,
    allow_empty_template: false,
    history_only: false,
    source_kind: "release"
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
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
    opts.on("--ipa PATH", "Compare the selected release source size with this IPA") do |path|
      options[:ipa_path] = path
    end
    opts.on("--sha256-file PATH", "Compare the IPA digest with this checksum file") do |path|
      options[:sha256_path] = path
    end
    opts.on("--tag TAG", "Validate this exact metadata release tag, including historical entries") do |tag|
      options[:tag] = tag
    end
    opts.on("--allow-empty-template", "Permit an empty versions array before the first release") do
      options[:allow_empty_template] = true
    end
    opts.on("--history-only", "Validate published source history without requiring metadata's next tag") do
      options[:history_only] = true
    end
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
    SideStoreSourceValidator.new(**options).validate!
    puts "SideStore/LiveContainer source is valid: #{File.expand_path(options[:source_path])}"
    if options[:ipa_path]
      suffix = options[:sha256_path] ? "size and SHA-256 match" : "size matches"
      puts "IPA #{suffix}: #{File.expand_path(options[:ipa_path])}"
    end
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue ValidationError => error
    warn "SideStore/LiveContainer source validation failed: #{error.message}"
    exit 1
  end
end
