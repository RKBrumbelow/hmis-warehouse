require 'csv'
module Export::HMISSixOneOne::Shared
  extend ActiveSupport::Concern
  included do
    include NotifierConfig
    include ArelHelper

    attr_accessor :file_path

    after_initialize do
      setup_notifier('HMIS Exporter 6.11')
    end
  end
  class_methods do
    def export_to_path export_scope:, path:, export: 
      export_path = File.join(path, file_name)
      export_id = export.export_id
      CSV.open(export_path, 'wb') do |csv|
        csv << clean_headers(hud_csv_headers)
        if paranoid? && export.include_deleted
          export_scope = export_scope.with_deleted
        end

        # Sometimes we're plucking directly, sometimes we're plucking from a unionized table
        # and we've already overridden the select columns, so we'll pluck the hud columns
        columns = columns_to_pluck
        if includes_union?
          columns = hud_csv_headers
        end
        export_scope.pluck_in_batches(*columns, batch_size: 10000) do |batch|
          cleaned_batch = batch.map do |row|
            row = Hash[hud_csv_headers.zip(row)]
            row[:ExportID] = export_id
            csv << clean_row(row: row, export: export).values
          end
        end
      end
    end

    # Override as necessary
    def clean_headers(headers)
      headers
    end

    # Override as necessary
    def clean_row(row:, export:)
      if export.faked_pii
        export.fake_data.fake_patterns.keys.each do |k|
          if row[k].present?
            row[k] = export.fake_data.fetch(field_name: k, real_value: row[k])
          end
        end
        row
      else
        row
      end
    end

    def columns_to_pluck
      @columns_to_pluck ||= hud_csv_headers.map do |k|
        if k == hud_key.to_sym
          arel_table[:id].as(self.connection.quote_column_name(hud_key)).to_sql
        elsif k == :ProjectID
          cast(p_t[:id], 'VARCHAR').as(self.connection.quote_column_name(:ProjectID)).to_sql
        elsif k == :OrganizationID
          cast(o_t[:id], 'VARCHAR').as(self.connection.quote_column_name(:OrganizationID)).to_sql
        else
          k
        end
      end
    end

    def export_enrollment_related! enrollment_scope:, project_scope:, path:, export:
      changed_scope = modified_within_range(range: (export.start_date..export.end_date), include_deleted: export.include_deleted)
      if export.include_deleted
        changed_scope = changed_scope.joins(enrollment_with_deleted: :project_with_deleted).merge(project_scope)
      else
        changed_scope = changed_scope.joins(enrollment: :project).merge(project_scope)
      end

      if export.include_deleted
        model_scope = joins(:enrollment_with_deleted).merge(enrollment_scope)
      else
        model_scope = joins(:enrollment).merge(enrollment_scope)
      end

      union_scope = from(
        arel_table.create_table_alias(
          model_scope.select(*columns_to_pluck, :id).union(changed_scope.select(*columns_to_pluck, :id)),
          table_name
        )
      )

      if columns_to_pluck.include?(:ProjectID)
        if export.include_deleted
          union_scope = union_scope.joins(enrollment_with_deleted: :project_with_deleted)
        else
          union_scope = union_scope.joins(enrollment: :project)
        end
      end

      export_to_path(
        export_scope: union_scope, 
        path: path, 
        export: export
      )

    end

    def includes_union?
      false
    end
  end
end