{
  :schema => {
    "$schema" => "http://www.archivesspace.org/archivesspace.json",
    "type" => "object",
    "uri" => "/repositories/:repo_id/collection_management_records",
    "properties" => {
      "uri" => {"type" => "string", "required" => false},
      
      "cataloged_note" => {"type" => "string", "required" => false},
      "processing_hours_per_foot_estimate" => {"type" => "string", "required" => false},
      "processing_total_extent" => {"type" => "string", "required" => false},
      "processing_total_extent_type" => {"type" => "string", "required" => false, "enum" => ["cassettes", "cubic_feet", "leafs", "linear_feet", "photographic_prints", "photographic_slides", "reels", "sheets", "volumes"]},
      "processing_hours_total" => {"type" => "string", "required" => false},
      "processing_plan" => {"type" => "string", "required" => false},
      "processing_priority" => {"type" => "string", "required" => false, "enum" => ["High", "Medium", "Low"]},
      "processing_status" => {"type" => "string", "required" => false, "enum" => ["New", "In Progress", "Completed"]},
      "processors" => {"type" => "string", "required" => false},
      "rights_determined" => {"type" => "boolean"},
      
      "linked_records" => {
        "type" => "array",
        "ifmissing" => "error",
        "minItems" => 1,
        "items" => {
          "type" => "object",
          "ref" => {"type" => [{"type" => "JSONModel(:accession) uri"},
                               {"type" => "JSONModel(:resource) uri"},
                               {"type" => "JSONModel(:digital_object) uri"}]}
        }
      }
    },

    "additionalProperties" => false
  }
}
