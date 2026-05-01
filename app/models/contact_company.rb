# == Schema Information
#
# Table name: contact_companies
#
#  id         :uuid             not null, primary key
#  deleted_at :datetime
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  company_id :uuid             not null
#  contact_id :uuid             not null
#
# Indexes
#
#  index_contact_companies_on_company_id_and_contact_id  (company_id,contact_id)
#  index_contact_companies_on_contact_id_and_company_id  (contact_id,company_id) UNIQUE
#  index_contact_companies_on_deleted_at                 (deleted_at)
#
# Foreign Keys
#
#  fk_rails_...  (company_id => contacts.id)
#  fk_rails_...  (contact_id => contacts.id)
#
class ContactCompany < ApplicationRecord
  include Wisper::Publisher

  belongs_to :contact
  belongs_to :company, class_name: 'Contact'

  # Validations
  validates :contact_id, presence: true
  validates :company_id, presence: true
  validates :contact_id, uniqueness: { scope: :company_id }
  validate :contact_must_be_person
  validate :company_must_be_company
  validate :cannot_link_to_self
  validate :must_belong_to_same_account

  # Scopes
  scope :active, -> { where(deleted_at: nil) }

  private

  def contact_must_be_person
    return unless contact

    return if contact.person?

    errors.add(:contact, 'must be a person')
  end

  def company_must_be_company
    return unless company

    return if company.company?

    errors.add(:company, 'must be a company')
  end

  def cannot_link_to_self
    return unless contact_id && company_id

    return unless contact_id == company_id

    errors.add(:base, 'Cannot link contact to itself')
  end

  # Single-tenant Community edition: contact and company always live in
  # the same account, so no cross-account check is needed. Kept as a
  # no-op so the `validate :must_belong_to_same_account` declaration on
  # line 36 has a corresponding method (it is inherited from the SaaS
  # tree where this guard is meaningful).
  def must_belong_to_same_account
    # no-op
  end

end

