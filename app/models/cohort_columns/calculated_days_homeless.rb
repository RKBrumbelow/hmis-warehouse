module CohortColumns
  class CalculatedDaysHomeless < ReadOnly
    attribute :column, String, lazy: true, default: :calculated_days_homeless
    attribute :translation_key, String, lazy: true, default: 'Calculated Days Homeless*'
    attribute :title, String, lazy: true, default: -> (model, attr) { _(model.translation_key)}

    def description
      'Days homeless on the effective date, or today'
    end

    def value(cohort_client) # OK
      cohort_client.calculated_days_homeless_on_effective_date
    end
  end
end
