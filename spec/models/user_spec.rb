require 'spec_helper'

describe User, type: :model do
  include_examples 'presentable'
  before do
    Features.slack.invites.enabled = true
    slack_invite_job = class_double(SlackInviteJob).as_stubbed_const(transfer_nested_constants: true)
    allow(slack_invite_job).to receive(:perform_async).at_least(1).times
  end
  subject { build_stubbed :user }

  it { should have_one :subscription }

  it { is_expected.to have_many(:status) }

  it { is_expected.to accept_nested_attributes_for :status }

  it { is_expected.to respond_to :status_count }

  it 'should have valid factory' do
    expect(FactoryGirl.create(:user)).to be_valid
  end

  it 'should be invalid without email' do
    expect(build_stubbed(:user, email: '')).to_not be_valid
  end

  it 'should be invalid with an invalid email address' do
    expect(build_stubbed(:user, email: 'user@foo,com')).to_not be_valid
  end

  it 'should be valid with all the correct attributes' do
    expect(subject).to be_valid
  end

  it 'should reject duplicate email addresses' do
    user = FactoryGirl.create(:user)
    expect(build_stubbed(:user, email: user.email)).to_not be_valid
  end

  it 'should reject email addresses identical up to case' do
    upcased_email = subject.email.upcase
    _existing_user = FactoryGirl.create(:user, email: upcased_email)
    expect(build_stubbed(:user, email: subject.email)).to_not be_valid
  end

  it 'should be invalid without password' do
    expect(build_stubbed(:user, password: '')).to_not be_valid
  end

  it 'should be invalid without matching password confirmation' do
    expect(build_stubbed(:user, password_confirmation: 'invalid')).to_not be_valid
  end

  it 'should be invalid with short password' do
    expect(build_stubbed(:user, password: 'aaa', password_confirmation: 'aaa')).to_not be_valid
  end

  it 'should respond to is_privileged?' do
    expect(FactoryGirl.build(:user)).to respond_to(:is_privileged?)
  end

  describe 'scopes' do
    it '#mail_receiver' do
      expect(User).to respond_to(:mail_receiver)
    end
  end

  describe 'slug generation' do
    subject { FactoryGirl.build(:user, slug: nil) }
    it 'should automatically generate a slug' do
      subject.save
      expect(subject.slug).to_not eq nil
    end

    it 'should be manually adjustable' do
      slug = 'this-is-a-slug'
      subject.slug = slug
      subject.save
      expect(User.find(subject.id).slug).to eq slug
    end

    it 'should be remade when the display name changes' do
      subject.save
      slug = subject.slug
      subject.update_attributes first_name: 'Shawn'
      expect(subject.slug).to_not eq slug
    end

    it 'should not be affected by multiple saves' do
      subject.save
      slug = subject.slug
      subject.save
      expect(subject.slug).to eq slug
    end
  end

  describe 'geocoding' do
    subject { build(:user, last_sign_in_ip: '85.228.111.204') }

    before(:each) do
      Geocoder.configure(:ip_lookup => :test)
      Geocoder::Lookup::Test.add_stub(
          '85.228.111.204', [
          {
              ip: '85.228.111.204',
              country_code: 'SE',
              country_name: 'Sweden',
              region_code: '28',
              region_name: 'Västra Götaland',
              city: 'Alingsås',
              zipcode: '44139',
              latitude: 57.9333,
              longitude: 12.5167,
              metro_code: '',
              areacode: ''
          }.as_json
      ]
      )

      Geocoder::Lookup::Test.add_stub(
          '50.78.167.161', [
          {
              ip: '50.78.167.161',
              country_code: 'US',
              country_name: 'United States',
              region_code: 'WA',
              region_name: 'Washington',
              city: 'Seattle',
              zipcode: '',
              latitude: 47.6062,
              longitude: -122.3321,
              metro_code: '819',
              areacode: '206'
          }.as_json
      ]
      )

    end

    it 'should perform geocode' do
      subject.save
      expect(subject.latitude).to_not eq nil
      expect(subject.longitude).to_not eq nil
      expect(subject.city).to_not eq nil
      expect(subject.country_name).to_not eq nil
      expect(subject.country_code).to_not eq nil
    end

    it 'should set user location' do
      subject.save
      expect(subject.latitude).to eq 57.9333
      expect(subject.longitude).to eq 12.5167
      expect(subject.city).to eq 'Alingsås'
      expect(subject.country_name).to eq 'Sweden'
      expect(subject.country_code).to eq 'SE'
    end

    it 'should change location if ip changes' do
      subject.save
      subject.update_attributes last_sign_in_ip: '50.78.167.161'
      expect(subject.city).to eq 'Seattle'
      expect(subject.country_name).to eq 'United States'
      expect(subject.country_code).to eq 'US'
    end

  end

  describe '#followed_project_tags' do
    it 'returns project tags for projects with project title and tags and a scrum tag' do
      project_1 = build_stubbed(:project, title: 'Big Boom', tag_list: ['Big Regret', 'Boom', 'Bang'])
      project_2 = build_stubbed(:project, title: 'Black hole', tag_list: [])
      allow(subject).to receive(:following_projects).and_return([project_1, project_2])
      expect(subject.followed_project_tags).to eq ["big regret", "boom", "bang", "big boom", "black hole", "scrum"]
    end
  end

  describe '#gravatar_url' do
    let(:email) { ' MyEmailAddress@example.com  ' }
    let(:user_hash) { '0bc83cb571cd1c50ba6f3e8a78ef1346' }
    let(:user) { User.new(email: email) }

    it 'should construct a link to the image at gravatar.com' do
      regex = /^http[s]:\/\/.*gravatar.*#{user_hash}/
      expect(user.gravatar_url).to match(regex)
    end

    it 'should be able to specify image size' do
      expect(user.gravatar_url(size: 200)).to match(/\?s=200&/)
    end
  end

  describe '.filter' do
    let(:params) { {} }

    context 'has filters' do
      before(:each) do
        @user1 = FactoryGirl.create(:user, latitude: 59.33, longitude: 18.06)
        @user2 = FactoryGirl.create(:user, latitude: -29.15, longitude: 27.74)
        @project = FactoryGirl.create(:project)
      end

      it 'filters users for project' do
        @user1.follow @project
        @user2.stop_following @project
        params['project_filter'] = @project.id

        results = User.filter(params).allow_to_display

        expect(results).to include(@user1)
        expect(results).not_to include(@user2)
      end

      context 'filters users for timezone area' do
        before(:each) do
          @current_user = FactoryGirl.create(:user, timezone_offset: 3600)
        end

        it 'filters user1 when choose In My Timezone' do
          params['timezone_filter'] = [@current_user.timezone_offset, @current_user.timezone_offset]

          results = User.filter(params).allow_to_display

          expect(results).to include(@user1)
          expect(results).not_to include(@user2)
        end

        it 'filters both users when choose Members Within 2 Timezones' do
          params['timezone_filter'] = [@current_user.timezone_offset - 3600, @current_user.timezone_offset + 3600]

          results = User.filter(params).allow_to_display

          expect(results).to include(@user1)
          expect(results).to include(@user2)
        end
      end

      it 'does not raise error when filters are empty' do
        params['project_filter'] = ''
        params['timezone_filter'] = ''

        expect { User.filter(params).allow_to_display }.to_not raise_error
      end
    end

    context 'no filters' do
      subject { User.filter(params).allow_to_display }

      before(:each) do
        FactoryGirl.create(:user, first_name: 'Bob', created_at: 5.days.ago)
        FactoryGirl.create(:user, first_name: 'Marley', created_at: 2.days.ago)
        FactoryGirl.create(:user, first_name: 'Janice', display_profile: false)
      end

      it 'ordered by creation date' do
        expect(subject.first.first_name).to eq('Bob')
      end

      it 'filtered by the display_profile property' do
        results = subject.map(&:first_name)
        expect(results).to include('Marley')
        expect(results).not_to include('Janice')
      end
    end

    describe '.find_by_github_username' do
      it 'returns the user if it exists' do
        user_with_github = FactoryGirl.create(:user, github_profile_url: 'https://github.com/sampritipanda')
        user_without_github = FactoryGirl.create(:user, github_profile_url: nil)
        expect(User.find_by_github_username('sampritipanda')).to eq user_with_github
      end

      it 'returns nil if no user exists' do
        expect(User.find_by_github_username('unknown-guy')).to be_nil
      end
    end

    describe 'user online?' do

      let(:user) { @user }

      before(:each) do
        @user = FactoryGirl.create(:user, updated_at: '2014-09-30 05:00:00 UTC')
      end

      after(:each) do
        Delorean.back_to_the_present
      end

      it 'returns true if touched in last 10 minutes' do
        Delorean.time_travel_to(Time.parse('2014-09-30 05:09:00 UTC'))
        expect(user).to be_online
      end

      it 'returns false if touched more then 10 minutes ago' do
        Delorean.time_travel_to(Time.parse('2014-09-30 05:12:00 UTC'))
        expect(user.online?).to eq false
      end
    end
  end

  describe 'incomplete profile' do

    let(:user) { FactoryGirl.create(:user, updated_at: '2014-09-30 05:00:00 UTC') }

    it 'returns true if bio empty' do
      user.bio = ''
      expect(user.incomplete?).to be_truthy
    end

    it 'returns true if skills empty' do
      user.skill_list = ''
      user.save
      expect(user.incomplete?).to be_truthy
    end

    it 'returns true if first_name empty' do
      user.first_name = ''
      expect(user.incomplete?).to be_truthy
    end

    it 'returns true if skills empty' do
      user.last_name = ''
      expect(user.incomplete?).to be_truthy
    end

    it 'returns false if all are complete' do
      expect(user.incomplete?).to be_falsey
    end

    it 'returns true with nil values' do
      expect(User.new.incomplete?).to be_truthy
    end
  end

  context 'karma' do

    describe '#commit_count_total' do

      subject(:user) { FactoryGirl.create(:user) }

      let!(:commit_count) { FactoryGirl.create(:commit_count, user: user, commit_count: 369) }

      context 'single commit count' do
        it 'returns totals commits over all projects' do
          expect(user.commit_count_total).to eq 369
        end
      end

      context 'multiple commit count' do
        let!(:commit_count_2) { FactoryGirl.create(:commit_count, user: user, commit_count: 123) }
        it 'returns totals commits over all projects' do
          expect(user.commit_count_total).to eq 492
        end
      end
    end

    describe '#number_hangouts_started_with_more_than_one_participant' do

      subject(:user) { FactoryGirl.create(:user) }

      let!(:event_instance) { FactoryGirl.create(:event_instance, user: user) }
      context 'single event instance' do
        it 'returns total number of hangouts started with more than one participant' do
          expect(user.number_hangouts_started_with_more_than_one_participant).to eq 1
        end
      end

      context 'two event instances' do
        let!(:event_instance2) { FactoryGirl.create(:event_instance, user: user) }
        it 'returns total number of hangouts started with more than one participant' do
          expect(user.number_hangouts_started_with_more_than_one_participant).to eq 2
        end
      end

    end


    describe '#hangouts_attended_with_more_than_one_participant' do
      subject(:user) {FactoryGirl.create(:user, hangouts_attended_with_more_than_one_participant: 1)}
      it 'returns 1' do
        expect(user.hangouts_attended_with_more_than_one_participant).to eq 1
      end
    end

    describe '#profile_completeness' do
      subject(:user) { FactoryGirl.create(:user) }
      it 'calculates profile completeness' do
        expect(user.profile_completeness).to eq 6
      end
    end

    describe '#activity' do
      subject(:user) { FactoryGirl.create(:user) }
      it 'calculates sign in activity' do
        expect(user.activity).to eq 0
      end
    end

    describe '#membership_length' do
      subject(:user) { FactoryGirl.create(:user) }
      it 'calculates membership length' do
        expect(user.membership_length).to eq 0
      end
    end

    describe '#membership_type' do
      subject(:user) { FactoryGirl.create(:user) }

      it 'returns membership type' do
        expect(user.membership_type).to eq 'Basic'
      end

      context 'premium member' do
        subject(:user) { FactoryGirl.create(:user) }
        let!(:premium) { FactoryGirl.create(:subscription, user: user) }

        it 'returns premium' do
          expect(user.membership_type).to eq 'Premium'
        end
      end
    end

    describe '#karma_total' do
      subject(:user) { FactoryGirl.create(:user) }
      it 'returns 0 when user initially created' do
        expect(user.karma_total).to eq 0
      end
      context 'once associated karma object is created' do
        subject(:user) { FactoryGirl.build(:user, karma: FactoryGirl.create(:karma, total: 50)) }
        it 'returns non zero' do
          expect(user.karma_total).to eq 50
        end
      end
    end

  end

  context 'destroying user' do
    it 'should soft destroy' do
       user = User.new({ email: 'doh@doh.com', password: '12345678' })
       user.save!
       user.destroy!
       expect(user.deleted_at).to_not eq nil
    end
  end

  context 'creating user' do
    it 'should not be possible to save a user with nil Karma' do
      user = User.new({ email: 'doh@doh.com', password: '12345678' })
      user.save!
      expect(user.karma).not_to be_nil
    end
    it 'should not override existing karma' do
      user = User.new({ email: 'doh@doh.com', password: '12345678' })
      user.karma = Karma.new(total: 50)
      user.save!
      expect(user.karma.total).to eq 50
    end
  end

  context 'look up stripe id from subscription' do
    let(:subscription) { mock_model(Subscription, save: true) }
    before { allow(subscription).to receive(:[]=) }

    it 'asks subscription for identifier' do
      expect(subscription).to receive :identifier
      subject.subscription = subscription
      subject.stripe_customer_id
    end

  end

end
