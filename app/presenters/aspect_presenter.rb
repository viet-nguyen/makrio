class AspectPresenter < BasePresenter
  def initialize(aspect)
    @aspect = aspect
  end

  def as_json(opts ={})
    { :id => @aspect.id,
      :name => @aspect.name,
    }
  end

  def to_json(options = {})
    as_json.to_json(options)
  end
end