require 'zip'
require 'csv'
require 'charlock_holmes'
require 'newrelic_rpm'

# Assumptions:
# The import is authoritative for the date range specified in the Export.csv file
# The import is authoritative for the projects specified in the Project.csv file
# There's no reason to have client records with no enrollments
# All tables that hang off a client also hang off enrollments

module Importers::HMISSixOneOne
  class Base
    include TsqlImport
    include NotifierConfig

    attr_accessor :logger, :notifier_config

    def initialize(
      file_path: 'var/hmis_import',
      data_source_id: ,
      logger: Rails.logger,
      debug: true,
      remove_files: true,
      deidentified: false,
      project_whitelist: false
    )
      setup_notifier('HMIS Importer 6.11')
      @data_source = GrdaWarehouse::DataSource.find(data_source_id.to_i)
      @file_path = file_path
      @logger = logger
      @debug = debug
      @soft_delete_time = Time.now.change(usec: 0) # Active Record milliseconds and Rails don't always agree, so zero those out so future comparisons work.
      @remove_files = remove_files
      @deidentified = deidentified
      @project_whitelist = project_whitelist
      setup_import(data_source: @data_source)
      log("De-identifying clients") if @deidentified
      log("Limiting to whitelisted projects") if @project_whitelist
    end

    def import!
      # return if already_running_for_data_source?
      # Provide Application locking so we can be sure we aren't already importing this data source
      GrdaWarehouse::DataSource.with_advisory_lock("hud_import_#{@data_source.id}") do
        @export = load_export_file()
        if @export.blank?
          log("Exiting, failed to find a valid export file")
          return
        end
        begin
          @range = set_date_range()
          clean_source_files()
          # reload the export file with new export id
          @export = nil
          @export = load_export_file()
          @export.effective_export_end_date = @effective_export_end_date
          @export.import!
          @projects = set_involved_projects()
          @projects.each(&:update_changed_project_types)
          @projects.each(&:import!)
          # Import data that's not directly related to enrollments
          remove_project_related_data()
          import_organizations()
          import_inventories()
          import_project_cocs()
          import_geographies()
          import_funders()
          import_affiliations()
          @import.save

          # Clients
          import_clients()
          @import.save

          # Enrollment related
          remove_enrollment_related_data()
          import_enrollments()
          import_enrollment_cocs()
          import_disabilities()
          import_employment_educations()
          import_exits()
          import_health_and_dvs()
          import_income_benefits()
          @import.save
          import_services()

          complete_import()
          match_clients()
          update_project_types()
          log("Import complete")
        ensure
          remove_import_files() if @remove_files
        end
      end # end with_advisory_lock
    end

    def remove_import_files
      import_file_path = "#{@file_path}/#{@data_source.id}"
      Rails.logger.info "Removing #{import_file_path}"
      FileUtils.rm_rf(import_file_path) if File.exists?(import_file_path)
    end

    def update_project_types
      GrdaWarehouse::Tasks::CalculateProjectTypes.new.run!
    end

    def match_clients
      GrdaWarehouse::Tasks::IdentifyDuplicates.new.run!
      GrdaWarehouse::Tasks::IdentifyDuplicates.new.match_existing!
    end

    def complete_import
      @data_source.update(last_imported_at: Time.now)
      @import.completed_at = Time.now
      @import.upload_id = @upload.id if @upload.present?
      @import.save
    end

    def import_enrollments()
      import_class(enrollment_source)
    end

    def import_exits()
      import_class(exit_source)
    end

    def import_services()
      import_class(service_source)
    end

    def import_enrollment_cocs()
      import_class(enrollment_coc_source)
    end

    def import_disabilities()
      import_class(disability_source)
    end

    def import_employment_educations()
      import_class(employment_education_source)
    end

    def import_health_and_dvs()
      import_class(health_and_dv_source)
    end

    def import_income_benefits()
      import_class(income_benefits_source)
    end

    def self.pre_calculate_source_hashes!
      importable_files.each do |_, klass|
        klass.pre_calculate_source_hashes!
      end
    end

    # This dump should be authoritative for any enrollment that was open during the
    # specified date range at any of the involved projects
    # Models this needs to handle
    # Enrollment
    # EnrollmentCoc
    # Disability
    # EmploymentEducation
    # Exit
    # HealthAndDv
    # IncomeBenefit
    # Services
    def remove_enrollment_related_data
      [
        enrollment_coc_source,
        disability_source,
        employment_education_source,
        health_and_dv_source,
        income_benefits_source,
        service_source,
      ].each do |klass|
        file = importable_files.key(klass)
        next unless @import.summary[klass.file_name].present?
        @import.summary[klass.file_name][:lines_restored] -= klass.public_send(:delete_involved, {
          projects: @projects,
          range: @range,
          data_source_id: @data_source.id,
          deleted_at: @soft_delete_time,
        })
      end

      # Exit and Enrollment are used in the calculation, so this has to be two steps.
      involved_exit_ids = exit_source.involved_exits(projects: @projects, range: @range, data_source_id: @data_source.id)
      involved_exit_ids.each_slice(1000) do |ids|
        exit_source.where(id: ids).update_all(DateDeleted: @soft_delete_time)
      end
      @import.summary['Exit.csv'][:lines_restored] -= involved_exit_ids.size
      involved_enrollment_ids = enrollment_source.involved_enrollments(projects: @projects, range: @range, data_source_id: @data_source.id)
      involved_enrollment_ids.each_slice(1000) do |ids|
        enrollment_source.where(id: ids).update_all(DateDeleted: @soft_delete_time)
      end
      @import.summary['Enrollment.csv'][:lines_restored] -= involved_enrollment_ids.size
    end

    # This dump should be authoritative for any inventory and ProjectCoC
    # that is connected to an included project
    def remove_project_related_data
      [
        inventory_source,
        project_coc_source,
        geography_source,
        funder_source,
        affiliation_source,
      ].each do |klass|
        file = importable_files.key(klass)
        next unless @import.summary[klass.file_name].present?
        @import.summary[klass.file_name][:lines_restored] -= klass.public_send(:delete_involved, {
          projects: @projects,
          range: @range,
          data_source_id: @data_source.id,
          deleted_at: @soft_delete_time,
        })
      end
    end

    def import_class klass
      log("Importing #{klass.name}")
      begin
        file = importable_files.key(klass)
        return unless @import.summary[file].present?
        stats = klass.import_related!(
          data_source_id: @data_source.id,
          file_path: @file_path,
          stats: @import.summary[file],
          soft_delete_time: @soft_delete_time
        )
        errors = stats.delete(:errors)
        setup_summary(klass.file_name)
        @import.summary[klass.file_name].merge!(stats)
        if errors.present?
          errors.each do |error|
            add_error(file_path: klass.file_name, message: error[:message], line: error[:line])
          end
        end
      rescue ActiveRecord::ActiveRecordError => exception
        message = "Unable to import #{klass.name}: #{exception.message}"
        add_error(file_path: klass.file_name, message: message, line: '')
      end
    end

    def import_clients
      import_class(client_source)
    end

    def import_organizations
      import_class(organization_source)
    end

    def import_inventories
      import_class(inventory_source)
    end

    def import_project_cocs
      import_class(project_coc_source)
    end

    def import_geographies
      import_class(geography_source)
    end

    def import_funders
      import_class(funder_source)
    end

    def import_affiliations
      import_class(affiliation_source)
    end

    def set_involved_projects
      project_source.load_from_csv(
        file_path: @file_path,
        data_source_id: @data_source.id
      )
    end

    def set_date_range
      Filters::DateRange.new(start: @export.ExportStartDate.to_date, end: @export.ExportEndDate.to_date)
    end

    def load_export_file
      begin
        @export ||= export_source.load_from_csv(
          file_path: @file_path,
          data_source_id: @data_source.id
        )
      rescue Errno::ENOENT => exception
        log('No valid Export.csv file found')
      end
      return nil unless @export&.valid?
      @export
    end

    def already_running_for_data_source?
      running = GrdaWarehouse::DataSource.advisory_lock_exists?("hud_import_#{@data_source.id}")
      if running
        logger.warn "Import of Data Source: #{@data_source.short_name} already running...exiting"
      end
      return running
    end

    def clean_source_files
      importable_files.each do |file_name, klass|
        source_file_path = "#{@file_path}/#{@data_source.id}/#{file_name}"
        next unless File.file?(source_file_path)
        destination_file_path = "#{source_file_path}_updating"
        file = open_csv_file(source_file_path)
        clean_source_file(destination_path: destination_file_path, read_from: file, klass: klass)
        @import.files << [klass.name, file_name]
        if File.exists?(destination_file_path)
          FileUtils.mv(destination_file_path, source_file_path)
        else
          # We failed at cleaning the import file, delete the source
          # So we don't accidentally import an unclean file
          File.delete(source_file_path) if File.exists?(source_file_path)
        end
      end
    end

    # Headers need to match our style
    def clean_header_row(source_headers, klass)
      indexed_headers = klass.hud_csv_headers.map do |k|
        [k.to_s.downcase, k]
      end.to_h
      source_headers.map do |k|
        indexed_headers[k.downcase].to_s
      end
    end

    def clean_source_file destination_path:, read_from:, klass:
      csv = CSV.new(read_from, headers: true)
      # read the first row so we can set the headers
      row = csv.shift
      headers = csv.headers
      csv.rewind # go back to the start for processing
      
      if headers.blank?
        msg = "Unable to import #{File.basename(read_from.path)}, no data"
        add_error(file_path: read_from.path, message: msg, line: '')
        return
      elsif header_valid?(headers, klass)
        # we need to accept different cased headers, but we need our
        # case for import, so we'll fix that up here and use ours going forward
        header = clean_header_row(headers, klass)
        write_to = CSV.open(
          destination_path,
          'wb',
          headers: header,
          write_headers: true,
          force_quotes: true
          )
      else
        msg = "Unable to import #{File.basename(read_from.path)}, header invalid: #{csv.headers.to_s}; expected a subset of: #{klass.hud_csv_headers}"
        add_error(file_path: read_from.path, message: msg, line: '')
        return
      end
      csv.each do |row|
        begin
          # remove any internal newlines
          row.each{ |k,v| row[k] = v&.gsub(/[\r\n]+/, ' ')&.strip }

          if @deidentified && klass.name == 'GrdaWarehouse::Import::HMISSixOneOne::Client'
            klass.deidentify_client_name row
          end
          if row.count == header.count
            row = set_useful_export_id(row: row, export_id: export_id_addition)
            track_max_updated(row)
            write_to << row
          else
            msg = "Line length is incorrect, unable to import:"
            add_error(file_path: read_from.path, message: msg, line: row.to_s)
          end
        rescue Exception => exception
          message = "Failed while processing #{read_from.path}, #{exception.message}:"
          add_error(file_path: read_from.path, message: message, line: row.to_s)
        end
      end
      write_to.close
    end

    def header_valid?(line, klass)
      # just make sure we don't have anything we don't know how to process
      (line&.map(&:downcase)&.map(&:to_sym) - klass.hud_csv_headers.map(&:downcase)).blank?
    end

    def short_line?(line, comma_count)
      CSV.parse_line(line).count < comma_count rescue line.count(',') < comma_count
    end

    def long_line?(line, comma_count)
      CSV.parse_line(line).count > (comma_count + 1) rescue line.count(',') > comma_count
    end

    def export_id_addition
      @export_id_addition ||= @range.start.strftime('%Y%m%d')
    end

    # make sure we have an ExportID in every file that
    # reflects the start date of the export
    def set_useful_export_id(row:, export_id:)
      row['ExportID'] = "#{row['ExportID']}_#{export_id_addition}"
      row
    end

    # figure out the maximum date this export set was updated
    def track_max_updated(row)
      @effective_export_end_date ||= '1900-01-01'.to_date
      if row['DateUpdated'].present? && row['DateUpdated'].to_date > @effective_export_end_date
        @effective_export_end_date = row['DateUpdated'].to_date
      end
    end

    def open_csv_file(file_path)
      file = File.read(file_path)
      # Look at the file to see if we can determine the encoding
      file_encoding = CharlockHolmes::EncodingDetector.
        detect(file).
        try(:[], :encoding)
      file_lines = IO.readlines(file_path).size - 1
      setup_summary(File.basename(file_path))
      @import.summary[File.basename(file_path)][:total_lines] = file_lines
      log("Processing #{file_lines} lines in: #{file_path}")
      File.open(file_path, "r:#{file_encoding}:utf-8")
    end

    def expand file_path:
      Rails.logger.info "Expanding #{file_path}"
      Zip::File.open(file_path) do |zipped_file|
        zipped_file.each do |entry|
          Rails.logger.info entry.name
          entry.extract([@local_path, File.basename(entry.name)].join('/'))
        end
      end
      FileUtils.rm(file_path)
    end

    def mark_upload_complete
      @upload.update(percent_complete: 100, completed_at: @import.completed_at)
    end

    def setup_summary(file)
      @import.summary[file] ||= {
        total_lines: -1,
        lines_added: 0,
        lines_updated: 0,
        lines_restored: 0,
        total_errors: 0,
      }
    end

    def importable_files
      self.class.importable_files
    end

    def self.importable_files
      {
        'Affiliation.csv' => affiliation_source,
        'Client.csv' => client_source,
        'Disabilities.csv' => disability_source,
        'EmploymentEducation.csv' => employment_education_source,
        'Enrollment.csv' => enrollment_source,
        'EnrollmentCoC.csv' => enrollment_coc_source,
        'Exit.csv' => exit_source,
        'Export.csv' => export_source,
        'Funder.csv' => funder_source,
        'HealthAndDV.csv' => health_and_dv_source,
        'IncomeBenefits.csv' => income_benefits_source,
        'Inventory.csv' => inventory_source,
        'Organization.csv' => organization_source,
        'Project.csv' => project_source,
        'ProjectCoC.csv' => project_coc_source,
        'Services.csv' => service_source,
        'Geography.csv' => geography_source,
      }.freeze
    end

    def self.affiliation_source
      GrdaWarehouse::Import::HMISSixOneOne::Affiliation
    end
    def affiliation_source
      self.class.affiliation_source
    end

    def self.client_source
      GrdaWarehouse::Import::HMISSixOneOne::Client
    end
    def client_source
      self.class.client_source
    end

    def self.disability_source
      GrdaWarehouse::Import::HMISSixOneOne::Disability
    end
    def disability_source
      self.class.disability_source
    end

    def self.employment_education_source
      GrdaWarehouse::Import::HMISSixOneOne::EmploymentEducation
    end
    def employment_education_source
      self.class.employment_education_source
    end

    def self.enrollment_source
      GrdaWarehouse::Import::HMISSixOneOne::Enrollment
    end
    def enrollment_source
      self.class.enrollment_source
    end

    def self.enrollment_coc_source
      GrdaWarehouse::Import::HMISSixOneOne::EnrollmentCoc
    end
    def enrollment_coc_source
      self.class.enrollment_coc_source
    end

    def self.exit_source
      GrdaWarehouse::Import::HMISSixOneOne::Exit
    end
    def exit_source
      self.class.exit_source
    end

    def self.export_source
      GrdaWarehouse::Import::HMISSixOneOne::Export
    end
    def export_source
      self.class.export_source
    end

    def self.funder_source
      GrdaWarehouse::Import::HMISSixOneOne::Funder
    end
    def funder_source
      self.class.funder_source
    end

    def self.health_and_dv_source
      GrdaWarehouse::Import::HMISSixOneOne::HealthAndDv
    end
    def health_and_dv_source
      self.class.health_and_dv_source
    end

    def self.income_benefits_source
      GrdaWarehouse::Import::HMISSixOneOne::IncomeBenefit
    end
    def income_benefits_source
      self.class.income_benefits_source
    end

    def self.inventory_source
      GrdaWarehouse::Import::HMISSixOneOne::Inventory
    end
    def inventory_source
      self.class.inventory_source
    end

    def self.organization_source
      GrdaWarehouse::Import::HMISSixOneOne::Organization
    end
    def organization_source
      self.class.organization_source
    end

    def self.project_source
      GrdaWarehouse::Import::HMISSixOneOne::Project
    end
    def project_source
      self.class.project_source
    end

    def self.project_coc_source
      GrdaWarehouse::Import::HMISSixOneOne::ProjectCoc
    end
    def project_coc_source
      self.class.project_coc_source
    end

    def self.service_source
      GrdaWarehouse::Import::HMISSixOneOne::Service
    end
    def service_source
      self.class.service_source
    end

    def self.geography_source
      GrdaWarehouse::Import::HMISSixOneOne::Geography
    end
    def geography_source
      self.class.geography_source
    end

    def setup_import data_source:
      @import = GrdaWarehouse::ImportLog.new
      @import.created_at = Time.now
      @import.data_source = data_source
      @import.summary = {}
      @import.import_errors = {}
      @import.files = []
      @import.save
    end

    def log(message)
      @notifier.ping message if @notifier
      logger.info message if @debug
    end

    def add_error(file_path:, message:, line:)
      file = File.basename(file_path)

      @import.import_errors[file] ||= []
      @import.import_errors[file] << {
         text: "Error in #{file}",
         message: message,
         line: line,
      }
      setup_summary(file)
      @import.summary[file][:total_errors] += 1
      log(message)
    end
  end
end
