module Window::Health
  class SignableDocumentsController < IndividualPatientController
    include WindowClientPathGenerator
    include HealthCareplan
    helper ChaHelper

    before_action :set_client, except: [:signature, :signed]
    before_action :set_patient, except: [:signature, :signed]
    before_action :set_careplan, except: [:signature, :signed]
    before_action :set_medications, except: [:signature, :signed]
    before_action :set_problems, except: [:signature, :signed]

    # This supports signing without logging in:
    skip_before_action :authenticate_user!, only: [:signature, :signed]
    skip_before_action :require_some_patient_access!, only: [:signature, :signed]

    def create
      @team = @careplan.team

      @signers = []
      @signers << { 'email': @patient.current_email, 'name': @patient.name }

      @doc = @careplan.signable_documents.build(signers: @signers, primary: true, user_id: current_user.id)

      @doc.pdf_content_to_upload = get_pdf

      if @doc.valid?
        @careplan.class.transaction do
          @careplan.signable_documents.where.not(id: @doc.id).update_all(primary: false)
          @doc.make_document_signable!
        end

        flash[:notice] = "Created a document (#{@doc.id}) for #{@doc.signers.map(&:email).join('; ')} to sign"
      else
        flash[:error] = "#{@doc.errors.full_messages.join('. ')}"
      end
      url_params = {client_id: @client.id, careplan_id: @careplan.id, id: @doc.id, email: @patient.current_email, hash: @doc.signer_hash(@patient.current_email)}
      url_params[:sign_out] = true if params[:sign_out].present?
      redirect_to polymorphic_path([:signature] + careplan_path_generator + [:signable_document], url_params)
      # redirect_back fallback_location: client_health_careplans_path(@client)
    end

    def remind
      @careplan = @patient.careplans.find(params[:careplan_id])
      @doc      = @careplan.primary_signable_document

      @doc.remind!(email)

      flash.notice = "Reminded #{email}"
      redirect_back fallback_location: client_health_careplans_path(@client)
    end

    def signed
      @doc = Health::SignableDocument.find(params[:id])
      if @doc.signer_hash(params[:email]) == params[:hash] && ! @doc.expired?
        if @doc.signature_request
          signed_at = Time.now
          @doc.signature_request.update(completed_at: signed_at)
          @doc.signature_request.careplan.update(provider_signed_on: signed_at)
        end
      end

      flash[:notice] = 'Thank you. Your Care Plan signature was submitted.'
    end

    def signature
      @state = :valid
      @doc = Health::SignableDocument.find(params[:id])
      if current_user.present?
        @doc.update(expires_at: Health::SignableDocument.patient_expiration_window)
      end
      sign_out(:user) if params[:sign_out].present?

      if @doc.signer_hash(params[:email]) == params[:hash] && ! @doc.expired? && ! @doc.signed?
        if @doc.signature_request && @doc.signature_request.is_a?(Health::SignatureRequests::PcpSignatureRequest)
          params[:post_sign_path] = signed_client_health_careplan_signable_document_path(
            client_id: params[:client_id],
            careplan_id: params[:careplan_id],
            id: @doc.id,
            hash: params[:hash],
            email: params[:email]
          )
        end
        @signature_request_url = @doc.signature_request_url(params[:email])
      elsif @doc.signed?
        @state = :signed
      elsif @doc.expired?
        @doc = nil
        @state = :expired
      else
        not_authorized!
        return
      end

    rescue HelloSign::Error, HelloSign::Error::Conflict
      render 'error'
    end

    private

    def get_pdf
      pdf = careplan_combine_pdf_object
      file_name = 'care_plan'
      @pdf = pdf.to_pdf

    end

  end
end
