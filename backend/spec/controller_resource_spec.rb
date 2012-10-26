require 'spec_helper'

describe 'Resources controller' do

  before(:each) do
    create(:repo)
  end


  it "lets you create a resource and get it back" do
    resource = JSONModel(:resource).from_hash("title" => "a resource", "id_0" => "abc123", "extents" => [{"portion" => "whole", "number" => "5 or so", "extent_type" => "reels"}])
    id = resource.save

    JSONModel(:resource).find(id).title.should eq("a resource")
  end


  it "lets you manipulate the record hierarchy" do

    resource = create(:json_resource)
    id = resource.id

    aos = []
    ["earth", "australia", "canberra"].each do |name|
      ao = create(:json_archival_object, {:ref_id => name,
                                          :title => "archival object: #{name}"})
      if not aos.empty?
        ao.parent = aos.last.uri
      end

      ao.resource = resource.uri
      ao.save
      aos << ao
    end

    tree = JSONModel(:resource_tree).find(nil, :resource_id => resource.id)

    tree.to_hash.should eq({
                             "jsonmodel_type" => "resource_tree",
                             "archival_object" => aos[0].uri,
                             "title" => "archival object: earth",
                             "children" => [
                                            {
                                              "jsonmodel_type" => "resource_tree",
                                              "archival_object" => aos[1].uri,
                                              "title" => "archival object: australia",
                                              "children" => [
                                                             {
                                                               "jsonmodel_type" => "resource_tree",
                                                               "archival_object" => aos[2].uri,
                                                               "title" => "archival object: canberra",
                                                               "children" => []
                                                             }
                                                            ]
                                            }
                                           ]
                           })


    # Now turn it on its head
    changed = {
      "jsonmodel_type" => "resource_tree",
      "archival_object" => aos[2].uri,
      "title" => "archival object: canberra",
      "children" => [
                     {
                       "jsonmodel_type" => "resource_tree",
                       "archival_object" => aos[1].uri,
                       "title" => "archival object: australia",
                       "children" => [
                                      {
                                        "jsonmodel_type" => "resource_tree",
                                        "archival_object" => aos[0].uri,
                                        "title" => "archival object: earth",
                                        "children" => []
                                      }
                                     ]
                     }
                    ]
    }

    JSONModel(:resource_tree).from_hash(changed).save(:resource_id => resource.id)
    changed.delete("uri")

    tree = JSONModel(:resource_tree).find(nil, :resource_id => resource.id)

    tree.to_hash.should eq(changed)
  end



  it "lets you update a resource" do
    resource = create(:json_resource)

    resource.title = "an updated resource"
    resource.save

    JSONModel(:resource).find(resource.id).title.should eq("an updated resource")
  end


  it "can handle asking for the tree of an empty resource" do
    resource = create(:json_resource)

    tree = JSONModel(:resource_tree).find(nil, :resource_id => resource.id)

    tree.should eq(nil)
  end


  it "adds an archival object to a resource when it's added to the tree" do
    ao = create(:json_archival_object)

    resource = create(:json_resource)

    tree = JSONModel(:resource_tree).from_hash(:archival_object => ao.uri,
                                               :children => [])

    tree.save(:resource_id => resource.id)

    JSONModel(:archival_object).find(ao.id).resource == "#{$repo}/resources/#{resource.id}"
  end


  it "lets you create a resource with a subject" do
    vocab = JSONModel(:vocabulary).from_hash("name" => "Some Vocab",
                                             "ref_id" => "abc"
                                             )
    vocab.save
    vocab_uri = JSONModel(:vocabulary).uri_for(vocab.id)
    subject = JSONModel(:subject).from_hash("terms" => [{"term" => "a test subject", "term_type" => "Cultural context", "vocabulary" => vocab_uri}],
                                            "vocabulary" => vocab_uri
                                            )
    subject.save

    resource = create(:json_resource, :subjects => [subject.uri])

    JSONModel(:resource).find(resource.id).subjects[0].should eq(subject.uri)
  end


  it "can give a list of all resources" do

    create(:json_resource, {:title => 'coal', :id_0 => '1'})
    create(:json_resource, {:title => 'wind', :id_0 => '2'})
    create(:json_resource, {:title => 'love', :id_0 => '3'})

    resources = JSONModel(:resource).all

    resources.any? { |res| res.title == "coal" }.should be_true
    resources.any? { |res| res.title == "wind" }.should be_true
    resources.any? { |res| res.title == "love" }.should be_true
  end

  it "lets you create a resource with an extent" do
    resource = create(:json_resource)

    JSONModel(:resource).find(resource.id).extents.length.should eq(1)
    JSONModel(:resource).find(resource.id).extents[0]["portion"].should eq("whole")
  end


  it "lets you create a resource with an instance and container" do
    resource = create(:json_resource, :instances => [{
                                                    "instance_type" => "text",
                                                    "container" => build(:json_container).to_hash
                                                    }])

    JSONModel(:resource).find(resource.id).instances.length.should eq(1)
    JSONModel(:resource).find(resource.id).instances[0]["instance_type"].should eq("text")
    JSONModel(:resource).find(resource.id).instances[0]["container"]["type_1"].should eq("A Container")
  end


  it "lets you edit a resource with an instance and container" do
    resource = create(:json_resource, :instances => [{
                                                    "instance_type" => "text",
                                                    "container" => build(:json_container).to_hash
                                                    }])


    r = JSONModel(:resource).find(resource.id)

    r.instances[0]["instance_type"] = "audio"

    r.save

    JSONModel(:resource).find(r.id).instances[0]["instance_type"].should eq("audio")
  end

  it "lets you create a resource with an instance with a container with a location (and the location is resolved)" do

    # create the resource with all the instance/container etc
    resource = create(:json_resource, 
                      :instances => [{
                        "instance_type" => "text",
                        "container" => build(:json_container, 
                                             :container_locations => [{
                                                'status' => 'current',
                                                'start_date' => '2012-05-14',
                                                'location' => create(:json_location).uri
                                                }]
                                            ).to_hash
                                      }])                                              

    JSONModel(:resource).find(resource.id, "resolve[]" => "location").instances[0]["container"]["container_locations"][0]["status"].should eq("current")
    JSONModel(:resource).find(resource.id, "resolve[]" => "location").instances[0]["container"]["container_locations"][0]["resolved"]["location"]["building"].should eq("129 West 81st Street")
  end


  it "throws an error if try to link to a non temporary location and have status set to previous" do
    # create a location
    location = create(:json_location)

    # create the resource with all the instance/container etc
    expect {
      resource = create(:json_resource, 
                        :instances => [{
                          "instance_type" => "text",
                          "container" => build(:json_container, 
                                               :container_locations => [{
                                                  'status' => 'previous',
                                                  'start_date' => '2012-05-14',
                                                  'location' => create(:json_location).uri
                                                  }]
                                              ).to_hash
                                        }])


    }.to raise_error
  end


  it "allows linking to a temporary location and with status set to previous" do
    # create a location
    location = create(:json_location, 
                      :temporary => 'loan')

    resource = create(:json_resource, 
                      :instances => [{
                        "instance_type" => "text",
                        "container" => build(:json_container, 
                                             :container_locations => [{
                                                'status' => 'previous',
                                                'start_date' => '2012-05-14',
                                                'end_date' => '2012-05-18',
                                                'location' => create(:json_location, 
                                                                     :temporary => 'loan').to_hash
                                                }]
                                            ).to_hash
                                      }])

      id = resource.id

      JSONModel(:resource).find(id, "resolve[]" => "location").instances[0]["container"]["container_locations"][0]["status"].should eq("previous")
      JSONModel(:resource).find(id, "resolve[]" => "location").instances[0]["container"]["container_locations"][0]["resolved"]["location"]["temporary"].should eq("loan")
  end


  it "correctly substitutes the repo_id in nested URIs" do

    location = create(:json_location)
    location_id = location.id

    resource = {
      "dates" => [],
      "extents" => [
                    {
                      "extent_type" => "cassettes",
                      "number" => "1",
                      "portion" => "whole"
                    }
                   ],
      "external_documents" => [],
      "id_0" => "test",
      "instances" => [
                      {
                        "container" => {
                          "barcode_1" => "test",
                          "container_locations" => [
                                                    {
                                                      "end_date" => "2012-10-26",
                                                      "location" => "/repositories/#{$repo_id}/locations/#{location_id}",
                                                      "note" => "test",
                                                      "start_date" => "2012-10-10",
                                                      "status" => "current"
                                                    }
                                                   ],
                          "indicator_1" => "test",
                          "type_1" => "test"
                        },
                        "instance_type" => "books",
                      }
                     ],
      "jsonmodel_type" => "resource",
      "notes" => [],
      "rights_statements" => [],
      "subjects" => [],
      "title" => "New Resource",
    }


    resource_id = JSONModel(:resource).from_hash(resource).save

    # Set our default repository to nil here since we're really testing the fact
    # that the :repo_id parameter is passed through faithfully, and the global
    # setting would otherwise mask the error.
    #
    JSONModel.with_repository(nil) do
      container_location = JSONModel(:resource).find(resource_id, :repo_id => $repo_id)["instances"][0]["container"]["container_locations"][0]
      container_location["location"].should eq("/repositories/#{$repo_id}/locations/#{location_id}")
    end
  end


  it "reports an eror when marking a non-temporary location as 'previous'" do
    location = create(:json_location)

    resource = JSONModel(:resource).
      from_hash("title" => "New Resource",
                "id_0" => "test2",
                "extents" => [{
                                "portion" => "whole",
                                "number" => "123",
                                "extent_type" => "cassettes"
                              }],
                "instances" => [{
                                  "instance_type" => "microform",
                                  "container" => {
                                    "type_1" => "test",
                                    "indicator_1" => "test",
                                    "barcode_1" => "test",
                                    "container_locations" => [{
                                                                "status" => "previous",
                                                                "start_date" => "2012-10-12",
                                                                "end_date" => "2012-10-26",
                                                                "location" => "/repositories/#{$repo_id}/locations/#{location.id}"
                                                              }]
                                  }
                                }])


    err = nil
    begin
      resource.save
    rescue
      err = $!
    end

    err.should be_an_instance_of(ValidationException)
    err.errors.keys.should eq(["instances/0/container/container_locations/0/status"])

  end


  it "supports resolving locations and subjects" do
    # location = create(:json_location)

    vocab = JSONModel(:vocabulary).from_hash("name" => "Some Vocab",
                                             "ref_id" => "abc"
                                             )
    vocab.save

    subject = JSONModel(:subject).from_hash("terms" => [{"term" => "a test subject", "term_type" => "Cultural context", "vocabulary" => vocab.uri}],
                                            "vocabulary" => vocab.uri
                                            )
    subject.save

    r = create(:json_resource, 
               :subjects => [subject.uri],
               :instances => [{
                  "instance_type" => "text",
                  "container" => build(:json_container, 
                                       :container_locations => [{
                                          'status' => 'current',
                                          'start_date' => '2012-05-14',
                                          'end_date' => '2012-05-18',
                                          'location' => create(:json_location).uri
                                          }]
                                      ).to_hash
                                }])


    resource = JSONModel(:resource).find(r.id, "resolve[]" => ["subjects", "location"])

    # yowza!
    resource["instances"][0]["container"]["container_locations"][0]["resolved"]["location"]["barcode"].should eq("010101100011")
    resource["resolved"]["subjects"][0]["terms"][0]["term"].should eq("a test subject")
  end



  it "creates an accession with a deaccession" do
    r = create(:json_resource, 
               :deaccessions => [
                  {
                    "whole_part" => false,
                    "description" => "A description of this deaccession",
                    "date" => {
                      "date_type" => "single",
                      "label" => "creation",
                      "begin" => "2012-05-14",
                    },
                  }
                ])
    
    JSONModel(:resource).find(r.id).deaccessions.length.should eq(1)
    JSONModel(:resource).find(r.id).deaccessions[0]["whole_part"].should eq(false)
    JSONModel(:resource).find(r.id).deaccessions[0]["date"]["begin"].should eq("2012-05-14")
  end


end
