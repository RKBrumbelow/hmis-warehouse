module GrdaWarehouse::Export::HMISSixOneOne
  class Export < GrdaWarehouse::Import::HMISSixOneOne::Export
    include ::Export::HMISSixOneOne::Shared
    attr_accessor :path
    self.hud_key = :ExportID
    setup_hud_column_access( GrdaWarehouse::Hud::Export.hud_csv_headers(version: '6.11') )

    def initialize(path:)
      super
      @path = path
    end

    def self.available_period_types
      {
        3 => 'Reporting period',
      }.freeze
    end

    def self.available_directives
      {
        2 => 'Full refresh',
      }.freeze
    end

    def self.available_hash_stati
      {
        1 => 'Unhashed',
        4 => 'SHA-256 (RHY)',
      }.freeze
    end

    def export!
      export_path = File.join(@path, self.class.file_name)
      CSV.open(export_path, 'wb') do |csv|
        csv << self.hud_csv_headers
        csv << self.attributes.slice(*hud_csv_headers.map(&:to_s)).values
      end
    end

  end
end