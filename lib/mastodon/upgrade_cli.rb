# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'

module Mastodon
  class UpgradeCLI < Thor
    include CLIHelper

    def self.exit_on_failure?
      true
    end

    CURRENT_STORAGE_SCHEMA_VERSION = 1

    option :dry_run, type: :boolean, default: false
    desc 'storage-schema', 'Upgrade storage schema of various file attachments to the latest version'
    long_desc <<~LONG_DESC
      Iterates over every file attachment of every record and, if its storage schema is outdated, performs the
      necessary upgraded to the latest one. In practice this means e.g. moving files to different directories.

      Will most likely take a long time.
    LONG_DESC
    def storage_schema
      progress = create_progress_bar(nil)
      dry_run  = options[:dry_run] ? ' (DRY RUN)' : ''
      upgraded = 0
      records  = 0

      klasses = [
        Account,
        CustomEmoji,
        MediaAttachment,
        PreviewCard,
      ]

      klasses.each do |klass|
        attachment_names = klass.attachment_definitions.keys

        klass.find_each do |record|
          attachment_names.each do |attachment_name|
            attachment = record.public_send(attachment_name)

            next if attachment.blank? || attachment.storage_schema_version >= CURRENT_STORAGE_SCHEMA_VERSION

            attachment.styles.each_key do |style|
              case Paperclip::Attachment.default_options[:storage]
              when :s3
                object = attachment.s3_object(style)
                attachment.instance_write(:storage_schema_version, CURRENT_STORAGE_SCHEMA_VERSION)
                upgraded_path = attachment.path(style)

                if upgraded_path != object.key && object.exists?
                  begin
                    object.move_to(upgraded_path) unless options[:dry_run]
                    upgraded += 1
                  rescue => e
                    progress.log(pastel.red("Error processing #{object.key}: #{e}"))
                  end
                end
              when :fog
                say('The fog storage driver is not supported for this operation at this time', :red)
                exit(1)
              when :filesystem
                previous_path = attachment.path(style)
                attachment.instance_write(:storage_schema_version, CURRENT_STORAGE_SCHEMA_VERSION)
                upgraded_path = attachment.path(style)

                if upgraded_path != previous_path
                  FileUtils.mkdir_p(File.dirname(upgraded_path)) unless options[:dry_run]

                  begin
                    FileUtils.mv(previous_path, upgraded_path) unless options[:dry_run]
                    upgraded += 1
                  rescue Errno::ENOENT
                    # The original file didn't exist for some reason
                  end
                end
              end

              progress.increment
            end
          end

          if record.changed?
            record.save
            records += 1
          end
        end
      end

      progress.total = progress.progress
      progress.finish

      say("Upgraded storage schema of #{upgraded} files across #{records} records#{dry_run}", :green, true)
    end
  end
end
