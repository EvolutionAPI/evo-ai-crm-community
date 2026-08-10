class CsatSurveyResponsePolicy < ApplicationPolicy
  def index?
    # Administrators or users with csat_survey_responses.read permission can list CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.read')
  end

  def show?
    # Administrators or users with csat_survey_responses.read permission can view CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.read')
  end

  def create?
    # Administrators or users with csat_survey_responses.create permission can create CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.write')
  end

  def update?
    # Administrators or users with csat_survey_responses.update permission can update CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.write')
  end

  def destroy?
    # Administrators or users with csat_survey_responses.delete permission can delete CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.delete')
  end

  def metrics?
    # Administrators or users with csat_survey_responses.read permission can view metrics
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.read')
  end

  def download?
    # Administrators or users with csat_survey_responses.read permission can download CSAT responses
    @user&.administrator? || @user&.has_permission?('csat_survey_responses.read')
  end
end

CsatSurveyResponsePolicy.prepend_mod_with('CsatSurveyResponsePolicy')
