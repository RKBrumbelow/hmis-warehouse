module CohortColumns
  class DisabilityVerificationDate < ReadOnly
    attribute :column, String, lazy: true, default: :disability_verification_date
    attribute :translation_key, String, lazy: true, default: 'Disability Verification Upload Date'
    attribute :title, String, lazy: true, default: -> (model, attr) { _(model.translation_key)}

    def date_format
      'll'
    end

    def value(cohort_client) # OK
      cohort_client.disability_verification_date&.to_s
    end
  end
end
