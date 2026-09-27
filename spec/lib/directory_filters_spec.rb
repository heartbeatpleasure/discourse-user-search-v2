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
