module WarehouseReports
  class ManageCasFlagsController < ApplicationController
    before_filter :set_flag, only: [:index]

    def index
      
      case @flag
      when :sync_with_cas
        @clients = hashed(
          client_scope.cas_active.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :full_housing_release
        
        @clients = hashed(
          client_scope.full_housing_release_on_file.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :limited_cas_release
        @clients = hashed(
          client_scope.limited_cas_release_on_file.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :disability_verified_on
        @clients = hashed(
          client_scope.verified_disability.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :dmh_eligible
        @clients = hashed(
          client_scope.dmh_eligible.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :va_eligible
        @clients = hashed(
          client_scope.va_eligible.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :hues_eligible
        @clients = hashed(
          client_scope.hues_eligible.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      when :hiv_positive
        @clients = hashed(
          client_scope.hiv_positive.
            order(:LastName, :FirstName).
            pluck(*client_fields)
        )
      end

    end

    def bulk_update
      @flag = available_flags.detect{|m| m == bulk_params[:flag]&.to_sym}
      if @flag.present?
        flashes =[]
        client_source.transaction do 
          client_ids = bulk_params[@flag.to_s].strip.split(/\s+/).uniq
          unflagged_count = unflag(column: @flag, client_ids: client_ids)
          flashes << "Removed <strong>#{cas_flags[@flag.to_sym]}</strong> from #{unflagged_count} clients".html_safe if unflagged_count > 0
          flagged_count = flag(column: @flag, client_ids: client_ids)
          flashes << "Added <strong>#{client_source.cas_columns[@flag.to_sym]}</strong> to #{flagged_count} clients".html_safe if flagged_count > 0

        end
        flash[:notice] = flashes.join('<br />').html_safe if flashes.any?
        Cas::SyncToCasJob.perform_later
      else
        flash[:error] = 'Unable to set CAS flag.'
      end
      redirect_to action: :index
    end

    private def set_flag
      @flag = available_flags.detect{|m| m == params[:cas_flag]&.to_sym} || :sync_with_cas
    end

    def available_flags
      cas_flags.keys
    end

    def cas_flags
      GrdaWarehouse::Hud::Client.cas_columns.reject{|m| m == :housing_release_status}
    end
    helper_method :cas_flags


    def client_fields
      [
        :id,
        :FirstName,
        :LastName,
      ]
    end

    def bulk_params
      params.require(:cas_flags).permit(
        :sync_with_cas,
        :housing_assistance_network_released_on,
        :disability_verified_on,
        :dmh_eligible,
        :va_eligible,
        :hues_eligible,
        :hiv_positive,
        :full_housing_release,
        :limited_cas_release,
        :flag
      )
    end

    def hashed(results)
      results.map do |row|
        Hash[client_fields.zip(row)]
      end
    end

    def unflag(column:, client_ids:)
      # Don't unflag housing_release_status since it's a ternary
      return 0 if housing_release_types.include?(column)
      default = column_default(column: column)
      client_scope.where.not(column_name(column: column) => default).
        where.not(id: client_ids).
        update_all(column_name(column: column) => default)
    end

    def flag(column:, client_ids:)
      default = column_default(column: column)
      set_to = if column == :full_housing_release
        'Full HAN Release'
      elsif column == :limited_cas_release
        'Limited CAS Release'
      elsif default === false
        true
      else
        Time.now
      end
      client_scope.where(id: client_ids).
        update_all(column_name(column: column) => set_to)
    end

    def column_default column:
      if housing_release_types.include?(column)
        nil
      else
        client_source.columns_hash[column.to_s].default
      end
    end

    def column_name column:
      if housing_release_types.include?(column)
        :housing_release_status
      else
       column
      end
    end

    def housing_release_types
      [:full_housing_release, :limited_cas_release]
    end
    helper_method :housing_release_types

    def client_scope
      GrdaWarehouse::Hud::Client.destination
    end

    def client_source
      GrdaWarehouse::Hud::Client
    end
  end
end