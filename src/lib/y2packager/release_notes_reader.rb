# ------------------------------------------------------------------------------
# Copyright (c) 2017 SUSE LLC, All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# ------------------------------------------------------------------------------

require "yast"
require "fileutils"
require "y2packager/package"
require "y2packager/release_notes_store"
require "y2packager/release_notes"
require "packages/package_downloader"
require "tmpdir"

Yast.import "Directory"
Yast.import "Pkg"

module Y2Packager
  # This class is able to read release notes for a given product
  #
  # Release notes for a product are available in a specific package which provides
  # "release-notes()" for the given product. For instance, a package which provides
  # "release-notes() = SLES" will provide release notes for the SLES product.
  #
  # This reader takes care of downloading the release notes package (if any),
  # extracting its content and returning release notes for a given language/format.
  class ReleaseNotesReader
    include Yast::Logger

    # Constructor
    #
    # @param release_notes_store [ReleaseNotesStore] Release notes store to cache data
    def initialize(release_notes_store = nil)
      @release_notes_store = release_notes_store
    end

    # Get release notes for a given product
    #
    # Release notes are downloaded and extracted to work directory.  When
    # release notes for a language "xx_XX" are not found, it will fallback to
    # "xx".
    #
    # @param product   [Y2Packager::Product] Product
    # @param user_lang [String]              Release notes language (falling back to "en_US"
    #                                        and "en")
    # @param format    [Symbol]              Release notes format (:txt or :rtf)
    # @return [String,nil] Release notes or nil if a release notes were not found
    #   (no package providing release notes or notes not found in the package)
    def release_notes_for(product, user_lang: "en_US", format: :txt)
      package = release_notes_package_for(product)
      if package.nil?
        log.info "No package containing release notes for #{product.name} was found"
        return nil
      end

      from_store = release_notes_store.retrieve(product.name, user_lang, format, package.version)
      if from_store
        log.info "Release notes for #{product.name} were found in the cache"
        return from_store
      end

      release_notes = build_release_notes(product, package, user_lang, format)
      if release_notes
        log.info "Release notes for #{product.name} were found"
        release_notes_store.store(release_notes)
      else
        log.warn "No release notes for #{product.name} were found in #{package.name}"
      end
      release_notes
    end

  private

    # Return the release notes package for a given product
    #
    # This method queries libzypp asking for the package which contains release
    # notes for the given product. It relies on the `release-notes()` tag.
    #
    # @param product [Product] Product
    # @return [Package,nil] Package containing the release notes; nil if not found
    def release_notes_package_for(product)
      provides = Yast::Pkg.PkgQueryProvides("release-notes()")
      release_notes_packages = provides.map(&:first).uniq
      package_name = release_notes_packages.find do |name|
        dependencies = Yast::Pkg.ResolvableDependencies(name, :package, "").first["deps"]
        dependencies.any? do |dep|
          dep["provides"].to_s.match(/release-notes\(\)\s*=\s*#{product.name}\s*/)
        end
      end
      return nil if package_name.nil?

      find_package(package_name)
    end

    # Valid statuses for packages containing release notes
    AVAILABLE_STATUSES = [:available, :selected].freeze

    # Find the latest available/selected package containing release notes
    #
    # @return [Package,nil] Package containing release notes; nil if not found
    def find_package(name)
      Y2Packager::Package
        .find(name)
        .select { |i| AVAILABLE_STATUSES.include?(i.status) }
        .sort_by { |i| Gem::Version.new(i.version) }
        .last
    end

    # Return release notes content for a package, language and format
    #
    # Release notes are downloaded and extracted to work directory.  When
    # release notes for a language "xx_XX" are not found, it will fallback to
    # "xx".
    #
    # @param package   [String] Release notes package name
    # @param user_lang [String] Language code ("en_US", "en", etc.)
    # @param format    [Symbol] Content format (:txt, :rtf, etc.).
    # @return [Array<String,String>] Array containing content and language code
    # @see release_notes_file
    def release_notes_content(package, user_lang, format)
      tmpdir = Dir.mktmpdir
      begin
        package.extract_to(tmpdir)
        file, lang = release_notes_file(tmpdir, user_lang, format)
        file ? [File.read(file), lang] : nil
      ensure
        FileUtils.remove_entry_secure(tmpdir)
      end
    end

    FALLBACK_LANGS = ["en_US", "en"].freeze
    # Return release notes file path for a given package, language and format
    #
    # Release notes are downloaded and extracted to work directory.  When
    # release notes for a language "xx_XX" are not found, it will fallback to
    # "xx".
    #
    # @param directory [String] Directory where release notes were uncompressed
    # @param user_lang [String] Language code ("en_US", "en", etc.)
    # @param format    [Symbol] Content format (:txt, :rtf, etc.)
    # @return [Array<String,String>] Array containing path and language code
    def release_notes_file(directory, user_lang, format)
      langs = [user_lang]
      langs << user_lang.split("_", 2).first if user_lang.include?("_")
      langs.concat(FALLBACK_LANGS)

      path = Dir.glob(
        File.join(directory, "**", "RELEASE-NOTES.{#{langs.join(",")}}.#{format}")
      ).first
      return nil if path.nil?
      [path, path[/RELEASE-NOTES\.(.+)\.#{format}\z/, 1]] if path
    end

    # Return release notes instance
    #
    # @param product   [Product] Product
    # @param package   [Package] Package containing release notes
    # @param user_lang [String]  User preferred language
    # @param format    [Symbol]  Release notes format
    # @return [ReleaseNotes] Release notes for given arguments
    def build_release_notes(product, package, user_lang, format)
      content, lang = release_notes_content(package, user_lang, format)
      return nil if content.nil?
      Y2Packager::ReleaseNotes.new(
        product_name: product.name,
        content:      content,
        user_lang:    user_lang,
        lang:         lang,
        format:       format,
        version:      package.version
      )
    end

    # Release notes store
    #
    # This store is used to cache already retrieved release notes.
    #
    # @return [ReleaseNotesStore] Release notes store
    def release_notes_store
      @release_notes_store ||= Y2Packager::ReleaseNotesStore.current
    end
  end
end
