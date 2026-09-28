# frozen_string_literal: true

RSpec.describe DiscourseUserSearch::DirectoryFilters do
  fab!(:eligible_user) { Fabricate(:user, trust_level: 2) }
  fab!(:tl0_user) { Fabricate(:user, trust_level: 0) }

  before do
    SiteSetting.user_search_enabled = true
    SiteSetting.user_search_min_trust_level = 1
  end

  def option_field(name:, searchable: false, show_on_profile: true)
    field =
      Fabricate(
        :user_field,
        name:,
        field_type: "dropdown",
        searchable:,
        show_on_profile:,
        show_on_user_card: false,
      )
    field.user_field_options.create!(value: "Female")
    field.user_field_options.create!(value: "Male")
    field
  end

  def set_user_field(user, field, value)
    UserCustomField.create!(
      user_id: user.id,
      name: "#{User::USER_FIELD_PREFIX}#{field.id}",
      value:,
    )
  end

  it "applies the configured minimum trust level" do
    users = described_class.apply_to_users(User.where(id: [eligible_user.id, tl0_user.id]), {})

    expect(users.pluck(:id)).to contain_exactly(eligible_user.id)
  end

  it "excludes accounts that are not eligible for the member directory" do
    eligible_user.update!(approved: true)
    inactive_user = Fabricate(:user, trust_level: 2, active: false)
    staged_user = Fabricate(:user, trust_level: 2, staged: true)
    suspended_user = Fabricate(:user, trust_level: 2, suspended_till: 1.day.from_now)
    silenced_user = Fabricate(:user, trust_level: 2, silenced_till: 1.day.from_now)
    unapproved_user = Fabricate(:user, trust_level: 2, approved: false)
    anonymous_user = Fabricate(:user, trust_level: 2)
    anonymous_master = Fabricate(:user, trust_level: 2)
    AnonymousUser.create!(user: anonymous_user, master_user: anonymous_master, active: true)

    SiteSetting.must_approve_users = true

    users =
      described_class.apply_to_users(
        User.where(
          id: [
            eligible_user.id,
            inactive_user.id,
            staged_user.id,
            suspended_user.id,
            silenced_user.id,
            unapproved_user.id,
            anonymous_user.id,
          ],
        ),
        {},
      )

    expect(users.pluck(:id)).to contain_exactly(eligible_user.id)
  end

  it "allows users again after a suspension or silence has expired" do
    user =
      Fabricate(
        :user,
        trust_level: 2,
        suspended_till: 1.minute.ago,
        silenced_till: 1.minute.ago,
      )

    users = described_class.apply_to_users(User.where(id: user.id), {})

    expect(users.pluck(:id)).to eq([user.id])
    expect(described_class.user_eligible?(user)).to eq(true)
  end

  it "matches configured option values and rejects unknown values" do
    field = option_field(name: "Gender")
    SiteSetting.user_search_gender_field_name = field.name
    set_user_field(eligible_user, field, "Female")

    valid =
      described_class.apply_to_users(
        User.where(id: eligible_user.id),
        hb_gender: "Female",
      )
    invalid =
      described_class.apply_to_users(
        User.where(id: eligible_user.id),
        hb_gender: "Unknown",
      )

    expect(valid.pluck(:id)).to eq([eligible_user.id])
    expect(invalid).to be_empty
  end

  it "does not expose an option field that is neither searchable nor public" do
    field = option_field(name: "Private field", searchable: false, show_on_profile: false)
    SiteSetting.user_search_gender_field_name = field.name
    set_user_field(eligible_user, field, "Female")

    expect(described_class.option_values_for(field.name)).to eq([])

    users =
      described_class.apply_to_users(
        User.where(id: eligible_user.id),
        hb_gender: "Female",
      )

    expect(users).to be_empty
  end

  it "allows an explicitly searchable option field even when it is not shown on profiles" do
    field = option_field(name: "Searchable field", searchable: true, show_on_profile: false)
    SiteSetting.user_search_gender_field_name = field.name
    set_user_field(eligible_user, field, "Female")

    expect(described_class.option_values_for(field.name)).to contain_exactly("Female", "Male")

    users =
      described_class.apply_to_users(
        User.where(id: eligible_user.id),
        hb_gender: "Female",
      )

    expect(users.pluck(:id)).to eq([eligible_user.id])
  end
end

RSpec.describe DiscourseUserSearch do
  it "supports the current directory query contract" do
    expect(described_class.directory_integration_compatible?).to eq(true)
  end
end
