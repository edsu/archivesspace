class AccessionsController < ApplicationController
  skip_before_filter :unauthorised_access, :only => [:index, :show, :new, :edit, :create, :update]
  before_filter :user_needs_to_be_a_viewer, :only => [:index, :show]
  before_filter :user_needs_to_be_an_archivist, :only => [:new, :edit, :create, :update]

  def index
    @accessions = Accession.all
  end

  def show
    @accession = Accession.find(params[:id], "resolve[]" => ["subjects", "ref"])
  end

  def new
    @accession = Accession.new({:accession_date => Date.today.strftime('%Y-%m-%d')})._always_valid!
  end

  def edit
    @accession = Accession.find(params[:id], "resolve[]" => ["subjects", "ref"])
    return render :partial => "accessions/edit_inline" if params[:inline]
    fetch_tree
  end


  def create
    handle_crud(:instance => :accession,
                :model => Accession,
                :on_invalid => ->(){ render action: "new" },
                :on_valid => ->(id){ redirect_to(:controller => :accessions,
                                                 :action => :show,
                                                 :id => id) })
  end

  def update
    handle_crud(:instance => :accession,
                :model => Accession,
                :obj => JSONModel(:accession).find(params[:id], "resolve[]" => ["subjects", "ref"]),
                :on_invalid => ->(){
                  return render action: "edit"
                },
                :on_valid => ->(id){
                  redirect_to :controller => :accessions, :action => :show, :id => id
                })
  end


  private

  def fetch_tree
    @accession_tree = {
      "id" => @accession.id,
      "title" => @accession.title,
      "jsonmodel_type" => "accession",
      "children" => []
    }
  end

end
