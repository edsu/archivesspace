require 'spec_helper'

def create_user(username = "test1", name = "Tester")
  user = JSONModel(:user).from_hash(:username => username,
                                    :name => name)

  # Probably more realistic than we'd care to think
  user.save(:password => "password")
end


describe 'User controller' do

  before(:each) do
    create_user
  end
  
  it "doesn't allow regular non-admin users to create new users" do

    ordinary_user = create(:user)
    
    expect {
      as_test_user(ordinary_user.username) do

        build(:json_user).save(:password => '123')
        
      end
    }.to raise_error(AccessDeniedException)
  end
  
  it "does allow regular admin users to create new users" do

    expect {
      build(:json_user).save(:password => '123')
    }.to_not raise_error(AccessDeniedException)
  end
  
  it "does allow anonymous users to create new users" do
    
    expect {
      as_anonymous_user do
        build(:json_user).save(:password => '123')
      end
    }.to_not raise_error(AccessDeniedException)
  end

  it "rejects an unknown username" do
    post '/users/notauserXXXXXX/login', params = { "password" => "wrongpwXXXXX"}
    last_response.should_not be_ok
    last_response.status.should eq(403)
  end


  it "expects a password" do
    post '/users/test1/login', params = {}
    last_response.should_not be_ok
    last_response.status.should eq(400)
  end


  it "rejects a bad password" do
    post '/users/test1/login', params = { "password" => "wrongpwXXXXX"}
    last_response.should_not be_ok
    last_response.status.should eq(403)
  end


  it "returns a session id if login is successful" do
    post '/users/test1/login', params = { "password" => "password"}
    last_response.should be_ok
    JSON(last_response.body)["session"].should match /^[0-9a-f]+$/
  end


  it "Treats the username as case insensitive" do
    post '/users/TEST1/login', params = { "password" => "password"}
    last_response.should be_ok
    last_response.status.should eq(200)
  end


  it "Rejects an invalid session" do
    get '/', params = {}, {"HTTP_X_ARCHIVESSPACE_SESSION" => "rubbish"}

    last_response.status.should eq(412)
    JSON(last_response.body)["code"].should eq ('SESSION_GONE')
  end


  it "yields a list of the user's permissions" do
    repo = create(:repo)

    group = JSONModel(:group).from_hash("group_code" => "newgroup",
                                        "description" => "A test group")
    group.grants_permissions = ["manage_repository"]
    group.member_usernames = ["test1"]
    id = group.save

    # as a part of the login process...
    post '/users/test1/login', params = { "password" => "password"}
    last_response.should be_ok
    JSON(last_response.body)["permissions"][repo.repo_code].should eq(["manage_repository"])

    # But also with the user
    user = JSONModel(:user).find('test1')
    user.permissions[repo.repo_code].should eq(["manage_repository"])
  end

end
