# frozen_string_literal: true

module TeamMemberSerializer
  extend self

  def serialize(user, **options)
    return nil unless user

    {
      id: user.id,
      uid: user.uid,
      name: user.name,
      display_name: user.display_name,
      email: user.email,
      role: user.role,
      confirmed: user.confirmed?,
      available_name: user.available_name,
      availability_status: user.availability_status,
      custom_attributes: user.custom_attributes || {},
      avatar_url: user.avatar_url,
      type: user.type
    }
  end

  def serialize_collection(users, **options)
    return [] unless users

    users.filter_map { |user| serialize(user, **options) }
  end
end
