class ArchivesSpaceService < Sinatra::Base

  Endpoint.post('/repositories/:repo_id/events')
    .description("Create an Event")
    .params(["event", JSONModel(:event), "The Event to create", :body => true],
            ["repo_id", :repo_id])
    .returns([200, :created],
             [400, :error]) \
  do
    handle_create(Event, :event)
  end


  Endpoint.post('/repositories/:repo_id/events/:event_id')
    .description("Update an Event")
    .params(["event_id", Integer, "The event ID to update"],
            ["event", JSONModel(:event), "The event data to update", :body => true],
            ["repo_id", :repo_id])
    .returns([200, :updated]) \
  do
    handle_update(Event, :event_id, :event)
  end


  Endpoint.get('/repositories/:repo_id/events')
    .description("Get a list of Events for a Repository")
    .params(["repo_id", :repo_id],
              *Endpoint.pagination)
    .returns([200, "[(:event)]"]) \
  do
    handle_listing(Event, params[:page], params[:page_size], params[:modified_since])
  end


  Endpoint.get('/repositories/:repo_id/events/:event_id')
    .description("Get an Event by ID")
    .params(["event_id", Integer, "The Event ID"],
            ["repo_id", :repo_id],
            ["resolve", [String], "A list of references to resolve and embed in the response",
             :optional => true]
            )
    .returns([200, "(:event)"],
             [404, '{"error":"Event not found"}']) \
  do
    json = Event.to_jsonmodel(params[:event_id])

    json_response(resolve_references(json.to_hash, params[:resolve]))
  end


  Endpoint.get('/repositories/:repo_id/events/linkable-records/list')
    .description("Get a list of records matching some search criteria that can be linked to an event")
    .params(["repo_id", :repo_id],
            ["q", /[\w0-9 -.]/, "The record title prefix to match"])
    .returns([200, "A list of matching records"]) \
  do
    result = Event.linkable_records_for(params[:q]).map {|record_type, records|
      records.map {|record| record.class.to_jsonmodel(record).to_hash}
    }.flatten

    json_response(result)
  end


  Endpoint.post('/repositories/:repo_id/events/:event_id/suppressed')
    .description("Suppress this record from non-managers")
    .params(["event_id", Integer, "The event ID to update"],
            ["suppressed", BooleanParam, "Suppression state"],
            ["repo_id", :repo_id])
    .preconditions(proc { current_user.can?(:manage_repository) })
    .returns([200, :suppressed]) \
  do
    sup_state = Event.get_or_die(params[:event_id]).set_suppressed(params[:suppressed])

    suppressed_response(params[:event_id], sup_state)
  end


end
