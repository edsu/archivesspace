module ASModel
  include JSONModel

  Sequel.extension :inflector


  @@linked_records = {}

  def self.linked_records
    @@linked_records
  end


  def before_create
    self.create_time = Time.now
    self.last_modified = Time.now
    super
  end


  def before_update
    self.last_modified = Time.now
    super
  end


  def self.included(base)
    base.instance_eval do
      plugin :optimistic_locking
    end

    base.extend(ClassMethods)
    base.extend(JSONModel)
  end


  def update_from_json(json, opts = {})
    old = JSONModel(json.class.record_type).from_hash(json.to_hash.merge(self.values)).to_hash
    changes = json.to_hash.merge(opts)

    old.each do |k, v|
      if not changes.has_key?(k)
        changes[k] = nil
      end
    end

    self.class.strict_param_setting = false

    self.update(self.class.map_json_to_db_types(json.class.schema, changes))

    id = self.save

    self.class.apply_linked_database_records(self, json, opts)

    id
  end


  def map_validation_to_json_property(columns, property)
    errors = self.errors.clone

    self.errors.clear

    errors.each do |error, msg|
      if error == columns
        self.errors[property] = msg
      else
        self.errors[error] = msg
      end
    end
  end


  module ClassMethods

    # Match a JSONModel object to an existing database association.
    #
    # This linkage manages records that contain subrecords:
    #
    #  - When storing a JSON blob in the database, the linkage indicates which
    #    parts of the JSON should be plucked out and stored as separate database
    #    records (with the appropriate associations)
    #
    #  - When requesting a record in JSON format, the linkage indicates which
    #    associated database records should be pulled back and included in the
    #    JSON returned.
    #
    # For example, this definition from subject.rb:
    #
    #   jsonmodel_hint(:the_property => :terms,
    #                  :contains_records_of_type => :term,
    #                  :corresponding_to_association  => :terms,
    #                  :always_resolve => true)
    #
    # Causes an incoming JSONModel(:subject) to have each of the objects in its
    # "terms" array to be coerced into a Sequel model (based on the :terms
    # association) and stored in the database.  The provided list of terms are
    # associated with the subject as it is stored, and these replace any
    # previous terms.
    #
    # The definition also causes Subject.to_jsonmodel(obj, :subject) to
    # automatically pull back the list of terms associated with the object and
    # include them in the response.  Here, the :always_resolve parameter
    # indicates that we want the actual JSON objects to be included in the
    # response, not just their URI references.

    def jsonmodel_hint(opts)
      opts[:association] = self.association_reflection(opts[:corresponding_to_association])
      opts[:jsonmodel] = opts[:contains_records_of_type]
      opts[:json_property] = opts[:the_property]

      ASModel.linked_records[self] ||= []
      ASModel.linked_records[self] << opts
    end


    def create_from_json(json, extra_values = {})
      self.strict_param_setting = false
      obj = self.create(map_json_to_db_types(json.class.schema, json.to_hash.merge(extra_values)))

      self.apply_linked_database_records(obj, json, extra_values)

      obj
    end


    JSON_TO_DB_MAPPINGS = {
      'boolean' => {
        :description => "JSON booleans become DB integers",
        :json_to_db => ->(bool) { bool ? 1 : 0 },
        :db_to_json => ->(int) { int === 1 }
      }
    }


    def map_json_to_db_types(schema, hash)
      hash = hash.clone
      schema['properties'].each do |property, definition|
        mapping = JSON_TO_DB_MAPPINGS[definition['type']]
        if mapping && hash.has_key?(property)
          hash[property] = mapping[:json_to_db].call(hash[property])
        end
      end

      hash
    end


    def map_db_types_to_json(schema, hash)
      hash = hash.clone
      schema['properties'].each do |property, definition|
        mapping = JSON_TO_DB_MAPPINGS[definition['type']]

        property = property.intern
        if mapping && hash.has_key?(property)
          hash[property] = mapping[:db_to_json].call(hash[property])
        end
      end

      hash
    end


    # Several JSONModels consist of logical subrecords that are stored as
    # separate models in the database (in separate tables).
    #
    # When we get a JSON blob for a record with subrecords, we want to create a
    # database record for each subrecords (or, if a URI referencing an existing
    # subrecord was given, use the existing object), then associate those
    # subrecords with the main record.
    #
    # If the :foreign_key option is given, any created subrecords will have
    # their column by that name set to the ID of the referring primary object.
    #
    # If the :delete_when_unassociating option is given, associated subrecords
    # being replaced will be fully deleted from the database.  This only makes
    # sense for a one-to-one or one-to-many relationship, where we want to
    # delete the object once it becomes unreferenced.
    #
    def apply_linked_database_records(obj, json, opts)
      (ASModel.linked_records[self] or []).each do |linked_record|

        # Remove the existing linked records
        if [:one_to_one, :one_to_many].include?(linked_record[:association][:type])
          # Delete the objects from the other table
          obj.send("#{linked_record[:association][:name]}_dataset").delete
        else
          # Just remove the links
          obj.send("remove_all_#{linked_record[:association][:name]}".intern)
        end

        # Read the subrecords from our JSON blob and fetch or create
        # the corresponding subrecord from the database.
        model = Kernel.const_get(linked_record[:association][:class_name])
        add_record_method = "add_#{linked_record[:association][:name].to_s.singularize}"

        (json[linked_record[:json_property]] or []).each do |json_or_uri|

          db_record = nil

          if json_or_uri.kind_of? String
            # A URI.  Just grab its database ID and look it up.
            db_record = model[JSONModel(linked_record[:jsonmodel]).id_for(json_or_uri)]
          else
            # Create a database record for the JSON blob and return its ID
            subrecord_json = JSONModel(linked_record[:jsonmodel]).from_hash(json_or_uri)

            if model.respond_to? :ensure_exists
              # Give our classes an opportunity to provide their own logic here
              db_record = model.ensure_exists(subrecord_json, obj)
            else
              extra_opts = {}.merge(opts)

              if linked_record[:association][:key]
                extra_opts[linked_record[:association][:key]] = obj.id
              end

              db_record = model.create_from_json(subrecord_json, extra_opts)
            end
          end

          obj.send(add_record_method, db_record) if db_record
        end
      end
    end


    def get_or_die(id, repo_id = nil)
      # For a minute there I lost myself...
      obj = (repo_id.nil? or !self.columns.include?(:repo_id)) ? self[id] : self[:id => id, :repo_id => repo_id]

      obj or raise NotFoundException.new("#{self} not found")
    end


    def sequel_to_jsonmodel(obj, model, opts = {})
      json = JSONModel(model).new(map_db_types_to_json(JSONModel(model).schema, obj.values.reject {|k, v| v.nil? }))

      # Sanity check
      if (obj[:repo_id] && opts[:repo_id] && (obj[:repo_id] != opts[:repo_id]))
        raise "Conflict between the repo_id in the DB and the repo_id passed in"
      end

      uri = json.class.uri_for(obj.id, {:repo_id => (obj[:repo_id] or opts[:repo_id])})
      json.uri = uri if uri

      # If there are linked records for this class, grab their URI references too
      (ASModel.linked_records[self] or []).each do |linked_record|

        model = Kernel.const_get(linked_record[:association][:class_name])

        records = obj.send(linked_record[:association][:name]).map {|linked_obj|
          if linked_record[:always_resolve]
            model.to_jsonmodel(linked_obj, linked_record[:jsonmodel]).to_hash
          else
            JSONModel(linked_record[:jsonmodel]).uri_for(linked_obj.id) or
              raise "Couldn't produce a URI for record type: #{linked_record[:type]}."
          end
        }

        json[linked_record[:json_property]] = records
      end

      json
    end


    def to_jsonmodel(obj, model, repo_id = nil, opts = {})
      if obj.is_a? Integer
        # An ID.  Get the Sequel row for it.
        obj = get_or_die(obj, repo_id)
      end

      sequel_to_jsonmodel(obj, model, opts.merge({:repo_id => repo_id}))
    end

  end
end
