{
  :schema => {
    "$schema" => "http://www.archivesspace.org/archivesspace.json",
    "type" => "object",
    "properties" => {
      "uri" => {"type" => "string", "required" => false},

      "agent_type" => {
        "type" => "string",
        "required" => false,
        "enum" => ["agent_person", "agent_corporation", "agent_software", "agent_family"]
      },

      "agent_contacts" => {
        "type" => "array",
        "items" => {"type" => "JSONModel(:agent_contact) uri_or_object"},
        "ifmissing" => "warn",
        "minItems" => 1
      },

    },
  },
}
