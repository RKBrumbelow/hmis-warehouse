module ReportGenerators::DataQuality::Fy2016
  class Q3 < Base
    ADULT = 18

    def run!
      if start_report(Reports::DataQuality::Fy2016::Q3.first)
        @answers = setup_questions()
        @support = @answers.deep_dup
        @all_clients = fetch_all_clients()
        if @all_clients.any?
          setup_age_categories()
          update_report_progress(percent: 25)
          @clients_with_issues = Set.new
          add_veteran_answers()
          add_entry_date_answers()
          add_head_of_household_answers()
          add_location_answers()
          update_report_progress(percent: 30)
          add_disabling_condition_answers()
        end
        finish_report()
      else
        Rails.logger.info 'No Report Queued'
      end
    end

    def fetch_all_clients
      columns = {
        client_id: :client_id, 
        age: :age, 
        project_type: act_as_project_overlay, 
        VeteranStatus: :VeteranStatus, 
        enrollment_group_id: :enrollment_group_id, 
        project_id: :project_id, 
        data_source_id: :data_source_id, 
        first_date_in_program: :first_date_in_program,
        last_date_in_program: :last_date_in_program,
        project_name: :project_name,
        RelationshipToHoH: :RelationshipToHoH,
        household_id: :household_id,
        CoCCode: :CoCCode,
        DisablingCondition: :DisablingCondition, 
      }
      
      all_client_scope.
        includes(enrollment: :enrollment_coc_at_entry).
        joins(:project).
        order(date: :asc).
        pluck(*columns.values).
        map do |row|
          Hash[columns.keys.zip(row)]
        end.group_by do |row|
          row[:client_id]
        end
    end

    def add_veteran_answers
      counted = Set.new # Only count each client once
      poor_quality = @all_clients.select do |id, enrollments|
        enrollment = enrollments.last
        age = enrollment[:age]
        veteran_status = enrollment[:VeteranStatus]
        [8,9,99,nil].include?(veteran_status) ||
        (veteran_status == 1 && age.present? && age < ADULT)
      end
      counted += poor_quality.keys
      @clients_with_issues += poor_quality.keys
      @answers[:q3_b2][:value] = poor_quality.size
      @support[:q3_b2][:support] = add_support(
        headers: ['Client ID', 'Vetetan Status', 'Age'],
        data: poor_quality.map do |id, enrollments|
          enrollment = enrollments.last
          [
            id, 
            HUD.no_yes_reasons_for_missing_data(enrollment[:VeteranStatus]),
            enrollment[:age]
          ]
        end
      )
      @answers[:q3_c2][:value] = ((counted.size.to_f / @adults.size) * 100).round(2)
    end

    def add_entry_date_answers
      counted = Set.new # Only count each client once
      poor_quality = @all_clients.select do |id, enrollments|
        # Find any overlapping enrollments within the same project
        overlap = false
        enrollments.group_by do |enrollment|
          enrollment[:project_id]
        end.select{|_,v| v.size > 1}.values.flatten(1).
        combination(2) do |en_1, en_2|
          overlap = enrollments_overlap?(en_1, en_2)
        end
        overlap
      end
      counted += poor_quality.keys
      @clients_with_issues += poor_quality.keys
      @answers[:q3_b3][:value] = poor_quality.size
      @support[:q3_b3][:support] = add_support(
        headers: ['Client ID', 'Most Recent Project', 'Entry Date', 'Exit Date'],
        data: poor_quality.map do |id, enrollments|
          enrollment = enrollments.last
          [
            id, 
            enrollment[:project_name],
            enrollment[:first_date_in_program],
            enrollment[:last_date_in_program],
          ]
        end
      )
      @answers[:q3_c3][:value] = ((counted.size.to_f / all_client_count) * 100).round(2)
    end

    def add_head_of_household_answers
      counted = Set.new # Only count each client once
      poor_quality = @all_clients.select do |id, enrollments|
        flag = false
        enrollment = enrollments.last
        if ! valid_household_relationship?(enrollment[:RelationshipToHoH])
          # we have a missing, or non-usable relationship
          flag = true
        else
          household = household_members(enrollment)
          relationships = household.map do |enrollment|
            enrollment[:RelationshipToHoH]
          end
          hoh_count = relationships.count(1)
          if hoh_count == 0
            # No one is marked as the head of household
            flag = true
          elsif hoh_count > 1
            # Too many heads of household
            flag = true
          end
        end
        flag
      end
      counted += poor_quality.keys
      @clients_with_issues += poor_quality.keys
      @answers[:q3_b4][:value] = poor_quality.size
      @support[:q3_b4][:support] = add_support(
        headers: ['Client ID', 'Relationship to HoH', 'Project', 'Entry Date', 'Exit Date'],
        data: poor_quality.map do |id, enrollments|
          enrollment = enrollments.last
          [
            id,
            enrollment[:RelationshipToHoH],
            enrollment[:project_name],
            enrollment[:first_date_in_program],
            enrollment[:last_date_in_program],
          ]
        end
      )
      @answers[:q3_c4][:value] = ((counted.size.to_f / all_client_count) * 100).round(2)
    end

    def add_location_answers
      counted = Set.new # Only count each client once
      poor_quality = @all_clients.select do |id, enrollments|
        flag = false
        enrollment = enrollments.last
        if ! head_of_household?(enrollment[:RelationshipToHoH])
          flag = false
        else
          # if the CoCCode doesn't match the approved pattern (including missing), flag it
          flag = ! valid_coc_code?(enrollment[:CoCCode])
        end

      end
      counted += poor_quality.keys
      @clients_with_issues += poor_quality.keys
      @answers[:q3_b5][:value] = poor_quality.size
      @support[:q3_b5][:support] = add_support(
        headers: ['Client ID', 'CoC Code', 'Project'],
        data: poor_quality.map do |id, enrollments|
          enrollment = enrollments.last
          [
            id, 
            enrollment[:CoCCode],
            enrollment[:project_name]
          ]
        end
      )
      # Only count against heads of household
      @answers[:q3_c5][:value] = ((counted.size.to_f / (adult_heads.count + other_heads.count)) * 100).round(2)
    end

    def add_disabling_condition_answers
      counted = Set.new # Only count each client once
      poor_quality = @all_clients.select do |id, enrollments|
        enrollment = enrollments.last
        flag = false
        if [8,9,99,nil].include?(enrollment[:DisablingCondition])
          flag = true
        elsif enrollment[:DisablingCondition] == 0
          flag = client_disabled?(enrollment: enrollment)
        end
        flag
      end
      counted += poor_quality.keys
      @clients_with_issues += poor_quality.keys
      @answers[:q3_b6][:value] = poor_quality.size
      @support[:q3_b6][:support] = add_support(
        headers: ['Client ID', 'Disabling Condition'],
        data: poor_quality.map do |id, enrollments|
          enrollment = enrollments.last
          [
            id, 
            HUD.disability_type(enrollment[:DisablingCondition]),
          ]
        end
      )
      @answers[:q3_c6][:value] = (counted.size.to_f / all_client_count).round(2) * 100
    end

    def enrollments_overlap?(en_1, en_2)
      en_1_start = en_1[:first_date_in_program]
      en_1_end = en_1[:last_date_in_program] || Date.today
      en_2_start = en_2[:first_date_in_program]
      en_2_end = en_2[:last_date_in_program] || Date.today
      # Excellent discussion of why this works:
      # http://stackoverflow.com/questions/325933/determine-whether-two-date-ranges-overlap
      en_1_start < en_2_end && en_1_end > en_2_start
    end

    def household_members(enrollment)
      @all_households ||= households.values.map{|m| m[:household]}.
        index_by do |enrollments|
          enrollment = enrollments.first
          [
            enrollment[:data_source_id], 
            enrollment[:project_id], 
            enrollment[:household_id], 
            enrollment[:first_date_in_program],
          ]
        end
      @all_households[
        [
          enrollment[:data_source_id], 
          enrollment[:project_id], 
          enrollment[:household_id], 
          enrollment[:first_date_in_program],
        ]
      ]
    end

    def setup_questions
      {
        q3_a1: {
          title:  nil,
          value: 'Data Element',
        },
        q3_b1: {
          title:  nil,
          value: 'Error Count',
        },
        q3_c1: {
          title:  nil,
          value: '% of Error Rate',
        },
        q3_a2: {
          title:  nil,
          value: 'Veteran Status (3.7)',
        },
        q3_a3: {
          title:  nil,
          value: 'Project Entry Date (3.10)',
        },
        q3_a4: {
          title:  nil,
          value: 'Relationship to Head of Household (3.15)',
        },
        q3_a5: {
          title:  nil,
          value: 'Client Location (3.16)',
        },
        q3_a6: {
          title:  nil,
          value: 'Disabling Condition (3.8)',
        },
        q3_b2: {
          title:  'Veteran Status (3.7) - Error Count',
          value: 0,
        },
        q3_c2: {
          title:  'Veteran Status (3.7) - % of Error Rate',
          value: 0,
        },
        q3_b3: {
          title:  'Project Entry Date (3.10) - Error Count',
          value: 0,
        },
        q3_c3: {
          title:  'Project Entry Date (3.10) - % of Error Rate',
          value: 0,
        },
        q3_b4: {
          title:  'Relationship to Head of Household (3.15) - Error Rate',
          value: 0,
        },
        q3_c4: {
          title:  'Relationship to Head of Household (3.15) - % of Error Rate',
          value: 0,
        },
        q3_b5: {
          title:  'Client Location (3.16) - Error Rate',
          value: 0,
        },
        q3_c5: {
          title:  'Client Location (3.16) - % of Error Rate',
          value: 0,
        },
        q3_b6: {
          title:  'Disabling Condition (3.8) - Error Rate',
          value: 0,
        },
        q3_c6: {
          title:  'Disabling Condition (3.8) - % of Error Rate',
          value: 0,
        },
      }
    end

  end
end