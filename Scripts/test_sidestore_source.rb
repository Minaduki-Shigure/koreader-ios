#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "update_sidestore_source"
require_relative "validate_sidestore_source"

class SideStoreSourceToolsTest < Minitest::Test
  TESTING_TEMPLATE_PATH = File.expand_path(
    "../platform/ios/sidestore-testing-source-template.json", __dir__
  )

  def setup
    @directory = Dir.mktmpdir("koreader-source-test")
    @source_path = File.join(@directory, "sidestore-source.json")
    @metadata_path = File.join(@directory, "release.json")
    @ipa_path = File.join(@directory, KOReaderSideStore::ASSET_NAME)
    @sha256_path = File.join(@directory, "#{KOReaderSideStore::ASSET_NAME}.sha256")
    write_json(@source_path, empty_source)
    write_metadata
    File.binwrite(@ipa_path, "first deterministic IPA fixture\n")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_empty_template_requires_explicit_permission
    assert validator(allow_empty_template: true).validate!

    error = assert_raises(ValidationError) { validator.validate! }
    assert_includes error.message, "--allow-empty-template"
  end

  def test_first_release_is_livecontainer_compatible_and_idempotent
    assert updater.update!
    source = read_json(@source_path)
    app = source.fetch("apps").fetch(0)
    version = app.fetch("versions").fetch(0)

    assert_equal %w[date downloadURL localizedDescription minOSVersion size version], version.keys.sort
    assert_equal "2026.7.1", version["version"]
    assert_equal "2026-09-02", version["date"]
    assert_equal release_description, version["localizedDescription"]
    assert_equal KOReaderSideStore.release_url("ios-v2026.7.1-b1"), version["downloadURL"]
    assert_equal File.size(@ipa_path), version["size"]
    assert_equal "14.0", version["minOSVersion"]
    assert_equal version["version"], app["version"]
    assert_equal version["date"], app["versionDate"]
    assert_equal version["localizedDescription"], app["versionDescription"]
    assert_equal version["downloadURL"], app["downloadURL"]
    assert_equal version["size"], app["size"]
    KOReaderSideStore::FORBIDDEN_KEYS.each { |key| refute source.to_s.include?(key) }

    write_checksum
    assert validator(ipa_path: @ipa_path, sha256_path: @sha256_path).validate!
    refute updater.update!
  end

  def test_tag_and_description_must_exactly_match_release_metadata
    error = assert_raises(SourceUpdateError) { updater(tag: "ios-v2026.7.1-b2").update! }
    assert_includes error.message, "--tag must exactly match"

    error = assert_raises(SourceUpdateError) { updater(description: "different").update! }
    assert_includes error.message, "--description must exactly match"
  end

  def test_duplicate_json_keys_are_rejected
    File.write(@source_path, %({"name":"a","name":"b"}\n))
    assert_includes assert_raises(SourceUpdateError) { updater.update! }.message, "duplicate JSON key"
    assert_includes assert_raises(ValidationError) { validator.validate! }.message, "duplicate JSON key"
  end

  def test_metadata_schema_and_release_tag_are_exact
    metadata = read_json(@metadata_path)
    metadata["extra"] = true
    write_json(@metadata_path, metadata)
    assert_includes assert_raises(ValidationError) { validator(allow_empty_template: true).validate! }.message,
                    "unsupported keys"

    metadata.delete("extra")
    metadata["releaseTag"] = "ios-v2026.07.1-b1"
    write_json(@metadata_path, metadata)
    assert_includes assert_raises(SourceUpdateError) { updater(tag: metadata["releaseTag"]).update! }.message,
                    "release metadata.releaseTag must be"
  end

  def test_stable_release_channel_keeps_the_public_source_unlocked
    metadata = read_json(@metadata_path)
    metadata["channel"] = "stable"
    write_json(@metadata_path, metadata)

    assert validator(allow_empty_template: true).validate!
    refute read_json(@source_path).dig("apps", 0, "beta")
  end

  def test_source_profiles_are_distinct_and_release_aliases_remain_compatible
    release = KOReaderSideStore.source_profile("release")
    testing = KOReaderSideStore.source_profile("testing")
    metadata = KOReaderSideStore.load_release_metadata(@metadata_path)

    assert_equal %w[release testing], KOReaderSideStore::SOURCE_KINDS
    assert_equal "ios-release", release.source_branch
    assert_equal KOReaderSideStore::SOURCE_NAME, release.source_name
    assert_equal KOReaderSideStore::SOURCE_IDENTIFIER, release.source_identifier
    assert_equal KOReaderSideStore::SOURCE_URL, release.source_url
    assert_equal KOReaderSideStore::ICON_URL, release.icon_url
    assert_equal KOReaderSideStore::APP_NAME, release.app_name
    assert_equal KOReaderSideStore::APP_BETA, release.app_beta
    refute release.app_beta

    assert_equal "ios-testing", testing.source_branch
    assert_equal "KOReader iOS Strict Offline Testing", testing.source_name
    assert_equal "io.github.minaduki-shigure.koreader-ios.testing-source",
                 testing.source_identifier
    assert_equal "KOReader Testing", testing.app_name
    refute testing.app_beta
    assert_equal "ios-v2026.7.1-b1",
                 KOReaderSideStore.expected_release_tag(metadata, source_kind: "release")
    assert_equal "ios-test-v2026.7.1-b1",
                 KOReaderSideStore.expected_release_tag(metadata, source_kind: "testing")

    error = assert_raises(KOReaderSideStore::Error) do
      KOReaderSideStore.source_profile("nightly")
    end
    assert_includes error.message, "release, testing"
  end

  def test_testing_template_matches_its_profile_and_rejects_release_validation
    template = testing_template
    testing = KOReaderSideStore.source_profile("testing")
    app = template.fetch("apps").fetch(0)

    assert_equal testing.source_name, template["name"]
    assert_equal testing.source_identifier, template["identifier"]
    assert_equal testing.source_url, template["sourceURL"]
    assert_equal testing.icon_url, template["iconURL"]
    assert_equal testing.app_name, app["name"]
    assert_equal testing.app_beta, app["beta"]
    assert_equal [], app["versions"]

    write_json(@source_path, template)
    assert validator(source_kind: "testing", allow_empty_template: true).validate!
    error = assert_raises(ValidationError) do
      validator(allow_empty_template: true).validate!
    end
    assert_includes error.message, "source.name"
  end

  def test_testing_source_update_is_idempotent_and_uses_testing_release_url
    write_json(@source_path, testing_template)
    tag = "ios-test-v2026.7.1-b1"
    testing_updater = updater(source_kind: "testing", tag: tag)

    assert testing_updater.update!
    refute testing_updater.update!

    app = read_json(@source_path).fetch("apps").fetch(0)
    version = app.fetch("versions").fetch(0)
    assert_equal "KOReader Testing", app["name"]
    refute app["beta"]
    assert_equal KOReaderSideStore.release_url(tag, source_kind: "testing"),
                 version["downloadURL"]
    assert_equal version["downloadURL"], app["downloadURL"]

    write_checksum
    assert validator(
      source_kind: "testing",
      ipa_path: @ipa_path,
      sha256_path: @sha256_path,
      tag: tag
    ).validate!
  end

  def test_release_and_testing_tags_and_urls_are_not_interchangeable
    release_tag = "ios-v2026.7.1-b1"
    testing_tag = "ios-test-v2026.7.1-b1"
    release_url = KOReaderSideStore.release_url(release_tag)
    testing_url = KOReaderSideStore.release_url(testing_tag, source_kind: "testing")

    assert_equal release_tag,
                 KOReaderSideStore.parse_release_url(release_url, "release URL")[:tag]
    assert_equal testing_tag, KOReaderSideStore.parse_release_url(
      testing_url, "testing URL", source_kind: "testing"
    )[:tag]
    assert_includes assert_raises(KOReaderSideStore::Error) {
      KOReaderSideStore.parse_release_url(testing_url, "testing URL")
    }.message, "ios-vX.Y.Z-bN"
    assert_includes assert_raises(KOReaderSideStore::Error) {
      KOReaderSideStore.parse_release_url(release_url, "release URL", source_kind: "testing")
    }.message, "ios-test-vX.Y.Z-bN"

    assert_includes assert_raises(SourceUpdateError) {
      updater(tag: testing_tag).update!
    }.message, "release metadata.releaseTag"
    write_json(@source_path, testing_template)
    assert_includes assert_raises(SourceUpdateError) {
      updater(source_kind: "testing", tag: release_tag).update!
    }.message, "testing tag"
    assert_includes assert_raises(ValidationError) {
      validator(
        source_kind: "testing", tag: release_tag, allow_empty_template: true
      ).validate!
    }.message, "testing tag"
  end

  def test_ios_marketing_version_can_advance_without_changing_upstream_tag
    write_metadata(
      marketing: "2026.7.2",
      build: "2",
      upstream: "v2026.07.1",
      tag: "ios-v2026.7.2-b2",
      description: "iOS-only maintenance release."
    )
    assert SideStoreSourceUpdater.new(
      source_path: @source_path,
      metadata_path: @metadata_path,
      ipa_path: @ipa_path,
      tag: "ios-v2026.7.2-b2",
      date: "2026-09-03",
      description: "iOS-only maintenance release."
    ).update!
    assert validator(tag: "ios-v2026.7.2-b2").validate!
  end

  def test_history_only_allows_valid_history_while_the_next_release_is_pending
    assert updater.update!
    write_metadata(
      marketing: "2026.7.2",
      build: "2",
      upstream: "v2026.07.1",
      tag: "ios-v2026.7.2-b2",
      description: "Pending iOS-only maintenance release."
    )

    assert validator(history_only: true).validate!
    error = assert_raises(ValidationError) { validator.validate! }
    assert_includes error.message, "does not contain release metadata tag"
  end

  def test_new_release_must_strictly_increase_marketing_and_build_versions
    assert updater.update!
    write_metadata(
      marketing: "2026.7.1",
      build: "2",
      upstream: "v2026.07.1",
      tag: "ios-v2026.7.1-b2",
      description: "Same marketing version."
    )
    error = assert_raises(SourceUpdateError) do
      updater(tag: "ios-v2026.7.1-b2", description: "Same marketing version.").update!
    end
    assert_includes error.message, "marketingVersion must be strictly greater"

    write_metadata(
      marketing: "2026.8.0",
      build: "1",
      upstream: "v2026.08.0",
      tag: "ios-v2026.8.0-b1",
      description: "Build went backwards."
    )
    error = assert_raises(SourceUpdateError) do
      updater(tag: "ios-v2026.8.0-b1", description: "Build went backwards.").update!
    end
    assert_includes error.message, "buildVersion must be greater"
  end

  def test_old_release_rerun_is_a_no_op_and_ipa_validation_selects_its_tag
    assert updater.update!
    first_metadata = read_json(@metadata_path)
    first_ipa = File.binread(@ipa_path)

    File.binwrite(@ipa_path, "second deterministic IPA fixture with another size\n")
    write_metadata(
      marketing: "2026.8.0",
      build: "2",
      upstream: "v2026.08.0",
      tag: "ios-v2026.8.0-b2",
      description: "Second release."
    )
    assert updater(
      tag: "ios-v2026.8.0-b2",
      description: "Second release.",
      date: "2026-09-03"
    ).update!

    write_json(@metadata_path, first_metadata)
    File.binwrite(@ipa_path, first_ipa)
    refute updater.update!
    write_checksum
    assert validator(
      ipa_path: @ipa_path,
      sha256_path: @sha256_path,
      tag: "ios-v2026.7.1-b1"
    ).validate!
  end

  def test_existing_release_metadata_is_immutable
    assert updater.update!
    source = read_json(@source_path)
    source.dig("apps", 0, "versions", 0)["localizedDescription"] = "Changed history."
    source.dig("apps", 0)["versionDescription"] = "Changed history."
    write_json(@source_path, source)

    error = assert_raises(SourceUpdateError) { updater.update! }
    assert_includes error.message, "different immutable fields"
    assert_includes error.message, "localizedDescription"
  end

  def test_rerun_preserves_the_original_published_date
    assert updater.update!
    refute updater(date: "2026-09-09").update!
    assert_equal "2026-09-02", read_json(@source_path).dig("apps", 0, "versions", 0, "date")
  end

  def test_validator_rejects_pal_and_nonportable_version_fields
    assert updater.update!
    KOReaderSideStore::FORBIDDEN_KEYS.each do |key|
      source = read_json(@source_path)
      source.dig("apps", 0, "versions", 0)[key] = key == "Build" ? {} : "value"
      write_json(@source_path, source)

      error = assert_raises(ValidationError) { validator.validate! }
      assert_includes error.message, "forbidden PAL/source fields"

      assert updater_fixture_reset
    end
  end

  def test_validator_rejects_legacy_field_drift
    assert updater.update!
    source = read_json(@source_path)
    source.dig("apps", 0)["versionDescription"] = "drifted"
    write_json(@source_path, source)

    error = assert_raises(ValidationError) { validator.validate! }
    assert_includes error.message, "legacy fields must match versions[0]"
  end

  def test_sha256_is_external_to_source_and_must_match_when_supplied
    assert updater.update!
    write_checksum("0" * 64)
    error = assert_raises(ValidationError) do
      validator(ipa_path: @ipa_path, sha256_path: @sha256_path).validate!
    end
    assert_includes error.message, "IPA SHA-256 mismatch"

    error = assert_raises(ValidationError) { validator(sha256_path: @sha256_path).validate! }
    assert_includes error.message, "--sha256-file requires --ipa"
  end

  private

  def empty_source
    {
      "name" => KOReaderSideStore::SOURCE_NAME,
      "identifier" => KOReaderSideStore::SOURCE_IDENTIFIER,
      "sourceURL" => KOReaderSideStore::SOURCE_URL,
      "subtitle" => "Strict-offline test source",
      "description" => "Test source description.",
      "iconURL" => KOReaderSideStore::ICON_URL,
      "website" => KOReaderSideStore::WEBSITE_URL,
      "tintColor" => KOReaderSideStore::TINT_COLOR,
      "apps" => [
        {
          "beta" => KOReaderSideStore::APP_BETA,
          "name" => KOReaderSideStore::APP_NAME,
          "bundleIdentifier" => KOReaderSideStore::BUNDLE_IDENTIFIER,
          "developerName" => KOReaderSideStore::DEVELOPER_NAME,
          "subtitle" => "Strict-offline reader",
          "localizedDescription" => "Test application description.",
          "iconURL" => KOReaderSideStore::ICON_URL,
          "tintColor" => KOReaderSideStore::TINT_COLOR,
          "versions" => []
        }
      ],
      "news" => []
    }
  end

  def release_description
    "First strict-offline release."
  end

  def write_metadata(marketing: "2026.7.1", build: "1", upstream: "v2026.07.1",
                     tag: "ios-v2026.7.1-b1", description: release_description)
    write_json(
      @metadata_path,
      {
        "marketingVersion" => marketing,
        "buildVersion" => build,
        "releaseTag" => tag,
        "upstreamTag" => upstream,
        "channel" => "beta",
        "localizedDescription" => description
      }
    )
  end

  def updater(tag: "ios-v2026.7.1-b1", description: release_description, date: "2026-09-02",
              source_kind: "release")
    SideStoreSourceUpdater.new(
      source_path: @source_path,
      metadata_path: @metadata_path,
      ipa_path: @ipa_path,
      tag: tag,
      date: date,
      description: description,
      source_kind: source_kind
    )
  end

  def validator(ipa_path: nil, sha256_path: nil, tag: nil, allow_empty_template: false,
                history_only: false, source_kind: "release")
    SideStoreSourceValidator.new(
      source_path: @source_path,
      metadata_path: @metadata_path,
      ipa_path: ipa_path,
      sha256_path: sha256_path,
      tag: tag,
      allow_empty_template: allow_empty_template,
      history_only: history_only,
      source_kind: source_kind
    )
  end

  def testing_template
    JSON.parse(File.read(TESTING_TEMPLATE_PATH))
  end

  def write_checksum(digest = Digest::SHA256.file(@ipa_path).hexdigest)
    File.write(@sha256_path, "#{digest}  #{File.basename(@ipa_path)}\n")
  end

  def updater_fixture_reset
    write_json(@source_path, empty_source)
    updater.update!
  end

  def read_json(path)
    JSON.parse(File.read(path))
  end

  def write_json(path, object)
    File.write(path, JSON.pretty_generate(object) + "\n")
  end
end
