require 'json-schema'


module JSONModel

  @@schema = {}
  @@types = {}
  @@models = {}
  @@custom_validations = {}
  @@protected_fields = []
  @@strict_mode = false
  @@client_mode = false


  def self.custom_validations
    @@custom_validations
  end

  def strict_mode(val)
    @@strict_mode = val
  end


  class ValidationException < StandardError
    attr_accessor :invalid_object
    attr_accessor :errors
    attr_accessor :warnings

    def initialize(opts)
      @invalid_object = opts[:invalid_object]
      @errors = opts[:errors]
      @warnings = opts[:warnings]
    end

    def to_s
      "#<:ValidationException: #{{:errors => @errors, :warnings => @warnings}.inspect}>"
    end
  end


  def self.JSONModel(source)
    # Checks if a model exists first; returns the model class
    # if it exists; returns false if it doesn't exist.
    if @@models.has_key?(source.to_s)
      @@models[source.to_s]
    else
      false
    end
  end

  def JSONModel(source)
    JSONModel.JSONModel(source)
  end


  # Yield all known JSONModel classes
  def models
    @@models
  end


  # Parse a URI reference like /repositories/123/archival_objects/500 into
  # {:id => 500, :type => :archival_object}
  def self.parse_reference(reference, opts = {})
    @@models.each do |type, model|
      id = model.id_for(reference, opts, true)
      if id
        return {:id => id, :type => type}
      end
    end

    nil
  end


  def self.destroy_model(type)
    type = type.to_s

    cls = @@models[type]

    if cls
      @@types.delete(cls)
      @@schema.delete(cls)
      @@models.delete(type)
    end
  end


  def self.load_schema(schema_name)
    if not @@models[schema_name]
      schema = File.join(File.dirname(__FILE__),
                         "schemas",
                         "#{schema_name}.rb")

      old_verbose = $VERBOSE
      $VERBOSE = nil
      entry = eval(File.open(schema).read)
      $VERBOSE = old_verbose

      parent = entry[:schema]["parent"]
      if parent
        load_schema(parent)

        base = @@models[parent].schema["properties"].clone
        properties = base.merge(entry[:schema]["properties"])

        entry[:schema]["properties"] = properties
      end

      self.create_model_for(schema_name, entry[:schema])
    end
  end


  def self.init(opts = {})

    @@init_args ||= nil

    if @@init_args
      return true
    end

    if opts.has_key?(:client_mode)
      @@client_mode = opts[:client_mode]
    end

    if opts.has_key?(:strict_mode)
      @@strict_mode = true
    end

    @@init_args = opts

    # Load all JSON schemas from the schemas subdirectory
    # Create a model class for each one.
    Dir.glob(File.join(File.dirname(__FILE__),
                       "schemas",
                       "*.rb")).sort.each do |schema|
      schema_name = File.basename(schema, ".rb")
      load_schema(schema_name)
    end

    require_relative "validations"

    true
  end


  def self.parse_jsonmodel_ref(ref)
    if ref.is_a? String and ref =~ /JSONModel\(:([a-zA-Z_\-]+)\) (.*)/
      [$1.intern, $2]
    else
      nil
    end
  end


  protected


  # Preprocess the schema to support ArchivesSpace extensions
  def self.preprocess_schema(type, schema, path = [])
    if schema["type"] == "object"
      schema["properties"].each do |property, defn|
        if defn.has_key?("ifmissing")
          defn["required"] = ["error", "warn"].include?(defn["ifmissing"])
        end

        self.preprocess_schema(type, defn, path + [property])
      end
    end
  end


  class ArchivesSpaceTypeAttribute < JSON::Schema::TypeAttribute
    extend JSONModel

    def self.validate(current_schema, data, fragments, validator, options = {})

      types = current_schema.schema['type']

      if JSONModel.parse_jsonmodel_ref(types)
        (model, qualifier) = JSONModel.parse_jsonmodel_ref(types)

        if qualifier == 'uri'
          if JSONModel(model).id_for(data, {}, true).nil?
            validation_error("The property '#{build_fragment(fragments)}' of type " +
                             "#{data.class} did not match the following type: #{types} in schema",
                             fragments, current_schema, self, options[:record_errors])
          end
        elsif qualifier == 'uri_or_object'
          if data.is_a? String
            if JSONModel(model).id_for(data, {}, true).nil?
            validation_error("The property '#{build_fragment(fragments)}' of type " +
                             "#{data.class} did not match the following type: #{types} in schema",
                             fragments, current_schema, self, options[:record_errors])
            end
          elsif data.is_a? Hash

            top_errors = validation_errors
            ::JSON::Validator.clear_errors

            JSONModel(model).from_hash(data, false)

            nested_errors = validation_errors

            nested_errors.each do |validation_error|
              # Add the fragment path to each nested exception to make them
              # findable from the root of the top-level json document.
              validation_error.fragments = fragments + validation_error.fragments
            end

            # Push them all back
            (top_errors + nested_errors).each do |error|
              ::JSON::Validator.validation_error(error)
            end

          else
            validation_error("The property '#{build_fragment(fragments)}' of type " +
                             "#{data.class} did not match the following type: #{types} in schema",
                             fragments, current_schema, self, options[:record_errors])
          end
        end
      else
        super
      end
    end
  end


  class ArchivesSpaceSchema < JSON::Schema::Validator
    def initialize
      super
      extend_schema_definition("http://json-schema.org/draft-03/schema#")
      @attributes["type"] = ArchivesSpaceTypeAttribute
      @uri = URI.parse("http://www.archivesspace.org/archivesspace.json")
    end


    def validate(current_schema, data, fragments, options = {})
      if current_schema.schema.has_key?("validations")
        current_schema.schema["validations"].each do |name|
          errors = JSONModel::custom_validations[name].call(data)

          errors.each do |field, msg|
            err = JSON::Schema::ValidationError.new("Validation failed for '#{field}': #{msg}",
                                                    fragments,
                                                    "custom_validation",
                                                    current_schema)
            JSON::Validator.validation_error(err)
          end
        end
      end

      super
    end

    JSON::Validator.register_validator(self.new)
  end


  # Create and return a new JSONModel class called 'type', based on the
  # JSONSchema 'schema'
  def self.create_model_for(type, schema)

    preprocess_schema(type, schema)

    cls = Class.new do

      # Define accessors for all variable names listed in 'attributes'
      def self.define_accessors(attributes)
        attributes.each do |attribute|

          if not method_defined? "#{attribute}"
            define_method "#{attribute}" do
              @data[attribute]
            end
          end


          if not method_defined? "#{attribute}="
            define_method "#{attribute}=" do |value|
              @validated = false
              @data[attribute] = value
            end
          end
        end
      end


      def self.to_s
        "JSONModel(:#{self.record_type})"
      end


      # Return the type of this JSONModel class (a keyword like
      # :archival_object)
      def self.record_type
        self.lookup(@@types)
      end


      # Add a custom validation to this model type.
      #
      # The validation is a block that takes a hash of properties and an
      # errors/warnings hash and adds any errors or warnings it finds.
      def self.add_validation(name, &block)
        raise "Validation name already taken: #{name}" if @@custom_validations[name]

        @@custom_validations[name] = block

        self.schema["validations"] ||= []
        self.schema["validations"] << name
      end


      # Create an instance of this JSONModel from the data contained in 'hash'.
      def self.from_hash(hash, raise_errors = true)
        validate(hash, raise_errors)

        # Note that I don't use the cleaned version here.  We want to keep
        # around the original extra stuff (and provide accessors for them
        # too), but just want to strip them out when converting back to JSON
        self.new(hash)
      end


      # Create an instance of this JSONModel from a JSON string.
      def self.from_json(s, raise_errors = true)
        self.from_hash(JSON(s), raise_errors)
      end


      # Given a numeric internal ID and additional options produce a URI reference.
      # For example:
      #
      #     JSONModel(:archival_object).uri_for(500, :repo_id => 123)
      #
      #  might yield "/repositories/123/archival_objects/500"
      #
      def self.uri_for(id = nil, opts = {})

        # Some schemas (like name schemas) don't have a URI because they don't
        # need endpoints.  That's fine.
        if not self.schema['uri']
          return nil
        end

        uri = self.schema['uri']

        if not id.nil?
          uri += "/#{id}"
        end

        self.substitute_parameters(uri, opts)
      end


      # The inverse of uri_for:
      #
      #     JSONModel(:archival_object).id_for("/repositories/123/archival_objects/500", :repo_id => 123)
      #
      #  might yield 500
      #
      def self.id_for(uri, opts = {}, noerror = false)
        if not self.schema['uri']
          if noerror
            return nil
          else
            raise "Missing a URI definition for class #{self.class}"
          end
        end

        pattern = self.schema['uri']
        pattern = pattern.gsub(/\/:[a-zA-Z_]+\//, '/[^/ ]+/')

        if uri =~ /#{pattern}\/([0-9]+)$/
          return $1.to_i
        else
          if noerror
            nil
          else
            raise "Couldn't make an ID out of URI: #{uri}"
          end
        end
      end


      # Return the type of the schema property defined by 'path'
      #
      # For example, type_of("names/items/type") might return a JSONModel class
      def self.type_of(path)
        type = self.schema_path_lookup(self.schema, path)["type"]

        ref = JSONModel.parse_jsonmodel_ref(type)

        if ref
          JSONModel.JSONModel(ref.first)
        else
          Kernel.const_get(type.capitalize)
        end
      end


      def initialize(params = {}, warnings = [])
        @data = self.class.keys_as_strings(params)
        @warnings = warnings

        self.class.define_accessors(@data.keys)
      end


      def [](key)
        @data[key.to_s]
      end


      def []=(key, val)
        @validated = false
        @data[key.to_s] = val
      end


      # Validate the current JSONModel instance and return a list of exceptions
      # produced.
      def _exceptions
        return @validated if @validated

        exceptions = {}
        if not @always_valid
          exceptions = self.class.validate(@data, false).reject{|k, v| v.empty?}
        end

        if @errors
          exceptions[:errors] = (exceptions[:errors] or {}).merge(@errors)
        end

        @validated = exceptions
        exceptions
      end


      def _warnings
        exceptions = self._exceptions

        if exceptions.has_key?(:warnings)
          exceptions[:warnings]
        else
          []
        end
      end


      # Set this object instance to always pass validation.  Used so the
      # frontend can create intentionally incomplete objects that will be filled
      # out by the user.
      def _always_valid!
        @always_valid = true
        self
      end


      # Update the values of the current JSONModel instance with the contents of
      # 'params', validating before accepting the update.
      def update(params)
        @validated = false
        replace(@data.merge(params))
      end


      # Replace the values of the current JSONModel instance with the contents
      # of 'params', validating before accepting the replacement.
      def replace(params)
        @validated = false
        @@protected_fields.each do |field|
          params[field] = @data[field]
        end

        @data = params
      end


      def to_s
        "#<JSONModel(:#{self.class.record_type}) #{@data.inspect}>"
      end

      def inspect
        self.to_s
      end


      # Produce a (possibly nested) hash from the values of this JSONModel.  Any
      # values that don't appear in the JSON schema will not appear in the
      # result.
      def to_hash
        cleaned = self.class.drop_unknown_properties(@data)
        self.class.validate(cleaned)

        cleaned
      end


      # Produce a JSON string from the values of this JSONModel.  Any values
      # that don't appear in the JSON schema will not appear in the result.
      def to_json
        self.to_hash.to_json
      end


      # Return the internal ID of this JSONModel.
      def id
        ref = JSONModel::parse_reference(self.uri)

        if ref
          ref[:id]
        else
          nil
        end
      end


      ## Supporting methods following from here
      protected

      # Return the JSON schema that defines this JSONModel class
      def self.schema
        self.lookup(@@schema)
      end


      # Find the entry for this JSONModel class in the supplied 'hash'.
      def self.lookup(hash)
        my_true_self = self.ancestors.find {|cls| hash[cls]}

        if my_true_self
          return hash[my_true_self]
        end

        return nil
      end


      # Given a (potentially nested) 'hash', remove any properties that don't
      # appear in the JSON schema defining this JSONModel.
      def self.drop_unknown_properties(hash, schema = nil)
        if schema.nil?
          self.drop_unknown_properties(hash, self.schema)
        else
          if not hash.is_a?(Hash)
            return hash
          end

          if schema["$ref"] == "#"
            # A recursive schema.  Back to the beginning.
            schema = self.schema
          end

          if not schema.has_key?("properties")
            return hash
          end

          result = {}

          hash.each do |k, v|
            k = k.to_s

            if schema["properties"].has_key?(k)
              if schema["properties"][k]["type"] == "object"
                result[k] = self.drop_unknown_properties(v, schema["properties"][k])
              elsif schema["properties"][k]["type"] == "array"
                result[k] = v.collect {|elt| self.drop_unknown_properties(elt, schema["properties"][k]["items"])}
              elsif v and v != ""
                result[k] = v
              end
            end
          end

          result
        end
      end


      def self.fragment_join(fragment, property = nil)
        fragment = fragment.gsub(/^#\//, "")

        if property and fragment != "" and fragment !~ /\/$/
          fragment = "#{fragment}/"
        end

        "#{fragment}#{property}"
      end


      def self.schema_path_lookup(schema, path)
        if path.is_a? String
          return self.schema_path_lookup(schema, path.split("/"))
        end

        if schema.has_key?('properties')
          schema = schema['properties']
        end

        if path.length == 1
          schema[path.first]
        else
          if schema[path.first]
            self.schema_path_lookup(schema[path.first], path.drop(1))
          else
            nil
          end
        end
      end


      # Given a list of error messages produced by JSON schema validation, parse
      # them into a structured format like:
      #
      # {
      #   :errors => {:attr1 => "(What was wrong with attr1)"},
      #   :warnings => {:attr2 => "(attr2 not quite right either)"}
      # }
      def self.parse_schema_messages(messages, validator)
        errors = {}
        warnings = {}

        messages.each do |message|

          if (message[:failed_attribute] == 'Properties' and
              message[:message] =~ /The property '(.*?)' did not contain a required property of '(.*?)'.*/)

            (path, property) = [message[:fragment], $2]

            schema = ::JSON::Validator.schemas[message[:schema].to_s].schema

            attribute = schema_path_lookup(schema, property)

            if not attribute
              attribute = schema_path_lookup(schema, fragment_join(message[:fragment], property))
            end

            if attribute and attribute['ifmissing'] == "error"
              errors[fragment_join(message[:fragment], property)] = ["Property is required but was missing"]
            else
              warnings[fragment_join(message[:fragment], property)] = ["Property was missing"]
            end

          elsif (message[:failed_attribute] == 'Pattern' and
                 message[:message] =~ /The property '#\/(.*?)' did not match the regex '(.*?)' in schema/)

            errors[fragment_join(message[:fragment])] = ["Did not match regular expression: #{$2}"]

          elsif (message[:failed_attribute] == 'MinLength' and
                 message[:message] =~ /The property '#\/(.*?)' was not of a minimum string length of ([0-9]+) in schema/)

            errors[fragment_join(message[:fragment])] = ["Must be at least #{$2} characters"]

          elsif (message[:failed_attribute] == 'MinItems' and
                 message[:message] =~ /The property '#\/(.*?)' did not contain a minimum number of items ([0-9]+) in schema/)

            errors[fragment_join(message[:fragment])] = ["The '#{$1}' array needs at least #{$2} elements"]

          elsif (message[:failed_attribute] == 'Enum' and
                 message[:message] =~ /The property '#\/(.*?)' value "(.*?)" .*values: (.*) in schema/)

            errors[fragment_join(message[:fragment])] = ["Invalid value '#{$2}'.  Must be one of: #{$3}"]

          elsif ((message[:failed_attribute] == 'Type' or message[:failed_attribute] == 'ArchivesSpaceType') and
                 message[:message] =~ /The property '#\/(.*?)' of type (.*?) did not match the following type: (.*?) in schema/)

            if $3 !~ /JSONModel/ || message[:failed_attribute] == 'ArchivesSpaceType'
              # We'll skip JSONModels because the specific problem with the
              # document will have already been listed separately.
              errors[fragment_join(message[:fragment])] = ["Must be a #{$3} (you provided a #{$2})"]
            end


          elsif (message[:failed_attribute] == 'custom_validation' and
                 message[:message] =~ /Validation failed for '(.*?)': (.*?) in schema /)
            errors[fragment_join(message[:fragment], $1)] = [$2]

          else
            errors[:unknown] = [message]
          end

        end

        {
          :errors => errors,
          :warnings => warnings,
        }
      end


      # Validate the supplied hash using the JSON schema for this model.  Raise
      # a ValidationException if there are any fatal validation problems, or if
      # strict mode is enabled and warnings were produced.
      def self.validate(hash, raise_errors = true)

        JSON::Validator.cache_schemas = true

        validator = JSON::Validator.new(self.schema,
                                        self.drop_unknown_properties(hash),
                                        :errors_as_objects => true,
                                        :record_errors => true)

        messages = validator.validate

        exceptions = self.parse_schema_messages(messages, validator)

        if raise_errors and not exceptions[:errors].empty? or (@@strict_mode and not exceptions[:warnings].empty?)
          raise ValidationException.new(:invalid_object => self.new(hash),
                                        :warnings => exceptions[:warnings],
                                        :errors => exceptions[:errors])
        end

        exceptions
      end


      # Given a URI like /repositories/:repo_id/something/:somevar, and a hash
      # containing keys and replacement strings, return a URI with the values
      # substituted in for their placeholders.
      #
      # As a side effect, removes any keys from 'opts' that were successfully
      # substituted.
      def self.substitute_parameters(uri, opts = {})
        matched = []
        opts.each do |k, v|
          old = uri
          uri = uri.gsub(":#{k}", v.to_s)

          if old != uri
            # Matched on this parameter.  Remove it from the passed in hash
            matched << k
          end
        end

        matched.each do |k|
          opts.delete(k)
        end

        uri
      end


      def self.keys_as_strings(hash)
        result = {}

        hash.each do |key, value|
          result[key.to_s] = value
        end

        result
      end


      # In client mode, mix in some extra convenience methods for querying the
      # ArchivesSpace backend service via HTTP.
      if @@client_mode
        require_relative 'jsonmodel_client'
        include JSONModel::Client
      end

    end

    cls.define_accessors(schema['properties'].keys)

    @@types[cls] = type
    @@schema[cls] = schema
    @@models[type] = cls

    cls.instance_eval do
      (@@init_args[:mixins] or []).each do |mixin|
        include(mixin)
      end
    end


  end


  def self.init_args
    @@init_args
  end


end
