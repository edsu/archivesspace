class Accession < Sequel::Model(:accession)
  include ASModel
  include Identifiers
  include Extents
  include Subjects
  include Dates
  include ExternalDocuments
  include RightsStatements
  include Deaccessions
  include Agents
  include Relationships

  enable_suppression
  corresponds_to JSONModel(:accession)
  set_model_scope :repository


  define_relationship(:name => :spawned,
                      :json_property => 'related_resources',
                      :contains_references_to_types => proc {[Resource]})



  def self.records_matching(query, max)
    self.this_repo.filter(:suppressed => 0).
         where(Sequel.like(Sequel.function(:lower, :title),
                           "#{query}%".downcase)).first(max)
  end


  def set_suppressed(val)
    self.suppressed = val ? 1 : 0
    save

    Event.handle_suppressed(self)

    val
  end


  def tree
    resources = self.linked_records(:spawned).map {|resource|
      {
        :title => resource.title,
        :id => resource.id,
        :node_type => 'resource',
        :record_uri => resource.uri,
      }
    }

    JSONModel(:accession_tree).
        from_hash(:title => self.title,
                  :id => self.id,
                  :node_type => 'accession',
                  :children => resources,
                  :record_uri => self.uri).to_hash
  end

end
