module GrdaWarehouse::Census
  class ByProjectType < Base
    include TsqlImport
    self.table_name = "nightly_census_by_project_types"

    scope :for_date_range, -> (start_date, end_date) do
      where(date: start_date.to_date .. end_date.to_date).order(:date)
    end

  end
end
