class GrdaWarehouse::DataSource < GrdaWarehouseBase
  validates :name, presence: true
  validates :short_name, presence: true
  
  has_many :import_logs
  has_many :services, class_name: GrdaWarehouse::Hud::Service.name, inverse_of: :data_source
  has_many :enrollments, class_name: GrdaWarehouse::Hud::Enrollment.name, inverse_of: :data_source
  has_many :exits, class_name: GrdaWarehouse::Hud::Exit.name, inverse_of: :data_source
  has_many :clients, class_name: GrdaWarehouse::Hud::Client.name, inverse_of: :data_source
  has_many :organizations, class_name: GrdaWarehouse::Hud::Organization.name, inverse_of: :data_source
  has_many :projects, class_name: GrdaWarehouse::Hud::Project.name, inverse_of: :data_source
  has_many :exports, class_name: GrdaWarehouse::Hud::Export.name, inverse_of: :data_source
  has_many :user_viewable_entities, as: :entity, class_name: 'GrdaWarehouse::Hud::UserViewableEntity'
  has_many :uploads
  
  scope :importable, -> { where.not(source_type: nil)}
  scope :destination, -> { where(source_type: nil)}
  scope :importable_via_samba, -> { importable.where(source_type: "samba")}
  scope :viewable_by, -> (user) do
    if user.roles.where( can_view_everything: true ).exists?
      current_scope
    else
      ds_t = quoted_table_name
      ve_t = GrdaWarehouse::Hud::UserViewableEntity.quoted_table_name
      p_t  = GrdaWarehouse::Hud::Project.quoted_table_name
      o_t  = GrdaWarehouse::Hud::Organization.quoted_table_name

      qc = -> (s) { connection.quote_column_name s }
      q  = -> (s) { connection.quote s }

      where(
        <<-SQL.squish

          EXISTS (
            SELECT 1 FROM
              #{ve_t}
              WHERE
                #{ve_t}.#{qc.('entity_id')}   = #{ds_t}.#{qc.('id')}
                AND
                #{ve_t}.#{qc.('entity_type')} = #{q.(sti_name)}
                AND
                #{ve_t}.#{qc.('user_id')}     = #{user.id}
          )
        OR
          EXISTS (
            SELECT 1 FROM
              #{ve_t}
              INNER JOIN
              #{o_t}
              ON
                #{ve_t}.#{qc.('entity_id')}   = #{o_t}.#{qc.('id')}
                AND
                #{ve_t}.#{qc.('entity_type')} = #{q.(GrdaWarehouse::Hud::Organization.sti_name)}
                AND
                #{ve_t}.#{qc.('user_id')}     = #{user.id}
              WHERE
                #{o_t}.#{qc.('data_source_id')} = #{ds_t}.#{qc.('id')}
                AND
                #{o_t}.#{qc.('DateDeleted')} IS NULL
          )
        OR
          EXISTS (
            SELECT 1 FROM
              #{ve_t}
              INNER JOIN
              #{p_t}
              ON
                #{ve_t}.#{qc.('entity_id')}   = #{p_t}.#{qc.('id')}
                AND
                #{ve_t}.#{qc.('entity_type')} = #{q.(GrdaWarehouse::Hud::Project.sti_name)}
                AND
                #{ve_t}.#{qc.('user_id')}     = #{user.id}
              WHERE
                #{p_t}.#{qc.('data_source_id')} = #{ds_t}.#{qc.('id')}
                AND
                #{p_t}.#{qc.('DateDeleted')} IS NULL
          )

        SQL
      )
    end
  end

  accepts_nested_attributes_for :projects

  def self.names
    importable.select(:id, :short_name).distinct.pluck(:short_name, :id)
  end

  def self.short_name id
    @short_names ||= importable.select(:id, :short_name).distinct.pluck(:id, :short_name).to_h
    @short_names[id]
  end

  def self.text_search(text)
    return none unless text.present?

    query = "%#{text}%"
    where(
      arel_table[:name].matches(query)
    )
  end

  # caculate the data coverage dates available for each data source
  # FIXME: this is a huge table scan across several tables so it
  # would be nice if the importers could maintain these dates somewhere
  def self.data_spans_by_id
    spans_by_id = {}
    dates_to_check = {
      GrdaWarehouse::Hud::Enrollment => 'EntryDate',
      GrdaWarehouse::Hud::Service => 'DateProvided',
      GrdaWarehouse::Hud::Exit => 'ExitDate'
    }
    dates_to_check.each do |model, field|
      # logger.debug "#{model}, #{field} #{model.count}"
      # idxes = model.connection.indexes(model.table_name).map{|i| [i.name] + i.columns}
      # logger.debug "indexes: #{idxes}"
      # logger.debug scope.explain
      scope = model.where(
        data_source_id: pluck(:id)
      ).group(
        :data_source_id
      ).select(
        "data_source_id, min(#{model.connection.quote_column_name(field)}), max(#{model.connection.quote_column_name(field)})"
      )
      model.connection.select_rows(scope.to_sql).each do |id, min, max|
        spans_by_id[id] ||= [nil, nil]
        spans_by_id[id][0] = min if spans_by_id[id][0].nil? || min < spans_by_id[id][0]
        spans_by_id[id][1] = max if spans_by_id[id][1].nil? || max > spans_by_id[id][1]
      end
    end
    spans_by_id
  end

  def data_span
    return unless enrollments.any?
    if self.id.present?
      self.class.where(id: self.id).data_spans_by_id[self.id]
    end
  end

  def manual_import_path
    "/tmp/uploaded#{file_path}"
  end

  def has_data?
    exports.any?
  end
end
