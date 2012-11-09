module ImportHelpers
  
  def handle_import
    batch = Batch.new(params[:batch_import])
    
    RequestContext.put(:repo_id, params[:repo_id])

    begin 
      batch.process
      json_response({:saved => batch.saved_uris}, 200)
    rescue ImportException => e
      json_response({:error => e.to_s}, 400)
    end
  end  
  
  class Batch
    attr_accessor :saved_uris
    
    def initialize(batch_object)
      @json_set = {}
      @as_set = {}
      @saved_uris = []
      
      batch_object.batch.each do |item|
         @json_set[item['uri']] = JSONModel::JSONModel(item['jsonmodel_type']).from_hash(item)
      end
      
    end
      
    # 1. Create ASModel objects from the JSONModel objects minus the references
    # 2. Update the nonce URIs of the JSONModel objects using their DB IDs
    # 3. Update JSONModel links using the real URIs
    # 4. Update ASModels with JSONModels with their references

    def process

      @json_set.each do |ref, json|
      
        unlinked = self.class.unlink(json)
        
        begin
        obj = Kernel.const_get(json.class.record_type.camelize).create_from_json(unlinked)
        @as_set[json.uri] = [obj.id, obj.class]
      
        # Now update the URI with the real ID
        json.uri.sub!(/\/[0-9]+$/, "/#{@as_set[json.uri][0].to_s}")
        rescue Exception => e
          raise ImportException.new({:invalid_object => json, :message => e.message})
        end
      end
      
      # Update the linked record pointers in the json set
      @json_set.each do |ref, json|
        self.class.correct_links(json, @json_set)
      end
      
      @as_set.each do |ref, a|

        obj = a[1].get_or_die(a[0])

        obj.update_from_json(@json_set[ref], {:lock_version => obj.lock_version}) 
        obj.save
        @saved_uris << @json_set[ref].uri
      end
      
    end
    
    def self.correct_links(json, set)
      data = json.to_hash
      data.each do |k, v| 
        if json.class.schema["properties"][k]["type"].match(/JSONModel/) and \
              v.is_a? String and \
              v.match(/\/.*[0-9]$/) and \
              !v.match(/\/vocabularies\/[0-9]+$/)

          data[k] = set[v].uri
        elsif json.class.schema["properties"][k]["type"] == "array" and \
              json.class.schema["properties"][k]["items"]["type"].match(/JSONModel/) and \
              v.is_a? Array
          data[k] = v.map { |u| (u.is_a? String and u.match(/\/.*[0-9]$/)) ? set[u].uri : u }
        end
      end
      
      json.set_data(data)
    end
    
    def self.unlink(json)
      unlinked = json.clone
      data = unlinked.to_hash
      data.each { |k, v| data.delete(k) if \
        (json.class.schema["properties"][k]["type"].match(/JSONModel/) or \
        (
        json.class.schema["properties"][k]["type"] == "array" and \
        json.class.schema["properties"][k]["items"]["type"].match(/JSONModel/)
        )) and v.is_a? String and !v.match(/\/vocabularies\/[0-9]+$/)
      }
      unlinked.set_data(data)
      unlinked
    end
  end


  class ImportException < StandardError
    attr_accessor :invalid_object
    attr_accessor :message

    def initialize(opts)
      @invalid_object = opts[:invalid_object]
      @message = opts[:message]
    end

    def to_s
      "#<:ImportException: #{{:invalid_object => @invalid_object, :message => @message}.inspect}>"
    end
  end

end


 