# frozen_string_literal: true

module Kquest
  module Structs
    class Document < Kquest::DB::Struct
      # The attachment column is the uploader's JSON string; reconstitute it
      # into an UploadedFile (open/each_line/read) — nil when unattached.
      def attachment
        return nil unless attachment_data
        Kquest::AttachmentUploader.uploaded_file(attachment_data)
      end
    end
  end
end
