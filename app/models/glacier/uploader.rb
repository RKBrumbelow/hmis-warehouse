# https://docs.aws.amazon.com/sdkforruby/api/Aws/Glacier/_client.html#upload_archive-instance_method

module Glacier
  class Uploader < AwsService
    attr_accessor :archive_name
    attr_accessor :file_stream
    attr_accessor :vault_name
    attr_accessor :start_at_chunk
    attr_accessor :upload_id
    attr_accessor :final_response
    attr_accessor :chunker

    attr_accessor :_client

    delegate :archive_id, :checksum, :location, to: :final_response, prefix: false
    delegate :archive_size, to: :chunker, prefix: false

    # Must be a power of two.
    # We break the upload into parts this big.
    MEGS_PER_PART = 32
    #MEGS_PER_PART = 2

    def initialize(vault_name:, file_stream:, archive_name:, start_at_chunk: 0, upload_id: nil)
      self.vault_name = vault_name
      self.file_stream = file_stream
      self.archive_name = archive_name
      self._client = Aws::Glacier::Client.new({
        region: 'us-east-1',
        access_key_id: ENV.fetch('GLACIER_AWS_ACCESS_KEY_ID'),
        secret_access_key: ENV.fetch('GLACIER_AWS_SECRET_ACCESS_KEY')
      })
      self.start_at_chunk = start_at_chunk
      self.upload_id = upload_id
    end

    # rescue Aws::Glacier::Errors::ServiceError if you want
    def init!
      create_vault_if_not_exists!
      initialize_upload!
    end

    # rescue Aws::Glacier::Errors::ServiceError if you want
    def upload!
      upload_multipart!
    end

    def successful?
      self.final_response.present?
    end

    private

    def create_vault_if_not_exists!
      _client.create_vault(vault_name: vault_name)
    end

    def initialize_upload!
      self.chunker = Chunker.new(file_stream: file_stream, part_megs: MEGS_PER_PART)

      if self.upload_id.nil?
        resp = _client.initiate_multipart_upload({
          part_size: self.chunker.part_size,
          vault_name: vault_name,
          archive_description: archive_name,
        })

        self.upload_id = resp.upload_id
      end

      Rails.logger.info "Using upload ID #{self.upload_id} for #{self.archive_name}"
    end

    def upload_multipart!
      chunk_count = -1

      self.chunker.each_chunk do |chunk|
        chunk_count += 1

        if chunk_count < start_at_chunk
          Rails.logger.info("Skipping chunk #{chunk_count}")
          next
        else
          Rails.logger.info { "Uploading chunk #{chunk_count}: #{chunk.range}" }
        end

        _client.upload_multipart_part({
          account_id: "-",
          body: chunk.body,
          checksum: chunk.digest,
          range: chunk.range,
          upload_id: self.upload_id,
          vault_name: vault_name
        })
      end

      Rails.logger.info("Finishing #{self.archive_name}: #{self.chunker.digest}")

      self.final_response = _client.complete_multipart_upload({
        account_id: "-",
        archive_size: self.chunker.archive_size,
        checksum: self.chunker.digest,
        upload_id: self.upload_id,
        vault_name: vault_name
      })
    end
  end
end