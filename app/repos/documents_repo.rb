# frozen_string_literal: true

module Kquest
  module Repos
    class DocumentsRepo < Kquest::DB::Repo
      def by_pk(id)
        documents.by_pk(id).one
      end

      def create(attrs)
        documents.command(:create).call(attrs)
      end

      def update(id, attrs)
        documents.by_pk(id).command(:update).call(attrs)
      end
    end
  end
end
