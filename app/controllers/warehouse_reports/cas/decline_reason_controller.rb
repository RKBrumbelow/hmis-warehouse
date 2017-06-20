module WarehouseReports::Cas
  class DeclineReasonController < ApplicationController
    before_action :require_can_view_reports!

    def index
      @reasons = GrdaWarehouse::CasReport.where.not( decline_reason: nil ).group(:decline_reason).count
      @reasons.sort_by(&:last).reverse
    end
  end
end