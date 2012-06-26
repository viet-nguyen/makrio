#   Copyright (c) 2010-2011, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class Post < ActiveRecord::Base
  include ApplicationHelper

  include Diaspora::Federated::Shareable

  
  include ActionView::Helpers::TextHelper
  include Diaspora::Likeable
  include Diaspora::Commentable
  include Diaspora::Shareable

  has_many :participations, :dependent => :delete_all, :as => :target

  attr_accessor :user_like

  xml_attr :provider_display_name

  has_many :mentions, :dependent => :destroy

  has_many :reshares, :class_name => "Reshare", :foreign_key => :parent_guid, :primary_key => :guid
  has_many :resharers, :class_name => 'Person', :through => :reshares, :source => :author

  has_many :remixes, :class_name => "Post", :foreign_key => :parent_guid, :primary_key => :guid
  has_many :remixers, :class_name => 'Person', :through => :reshares, :source => :author


  belongs_to :parent, :class_name => 'Post', :foreign_key => :parent_guid, :primary_key => :guid
  belongs_to :root, :class_name => 'Post', :foreign_key => :root_guid, :primary_key => :guid


  belongs_to :o_embed_cache

  before_create :set_root_guid

  after_create do
    self.touch(:interacted_at)
  end

  mount_uploader :screenshot, ScreenshotUploader
  #scopes
  scope :includes_for_a_stream, includes(:o_embed_cache, {:author => :profile}, :mentions => {:person => :profile}) #note should include root and photos, but i think those are both on status_message


  scope :commented_by, lambda { |person|
    select('DISTINCT posts.*').joins(:comments).where(:comments => {:author_id => person.id})
  }

  scope :liked_by, lambda { |person|
    joins(:likes).where(:likes => {:author_id => person.id})
  }

  def remixes
    Post.where(:parent_guid => self.guid)
  end

  def self.newer(post)
    where("posts.created_at > ?", post.created_at).reorder('posts.created_at ASC').first
  end

  def self.older(post)
    where("posts.created_at < ?", post.created_at).reorder('posts.created_at DESC').first
  end

  def self.featured_and_by_author(author)
    where(:featured => true) | where(:author_id => author.id)
  end

  def self.visible_from_author(author, current_user=nil)
    if current_user.present?
      current_user.posts_from(author)
    else
      author.posts.all_public
    end
  end

  def toggle_featured!
    self.featured = !featured
    save!
  end

  def set_absolute_root!
    self.root = absolute_root
    self.save!
  end

  def remix_siblings
    base_guid = original? ? guid : self.parent.root_guid
    Post.where(:root_guid => base_guid) 
  end

  def absolute_root
    return nil if parent_guid.blank?

    current = self
    while(current.parent.present? || current.is_a?(Reshare))
      current = current.parent
    end

    current
  end

  def set_root_guid
    return true if original?

    if self.parent.original?
      self.root_guid = self.parent.guid
    else
      self.root_guid = self.parent.root_guid
    end
  end

  def original?
    parent_guid.blank? && root_guid.blank?
  end

  def post_type
    self.class.name
  end

  def raw_message; ""; end
  def mentioned_people; []; end
  def photos; []; end
  def text(opts={}); raw_message; end

  def plain_text
    sanitize(raw_message, :tags=>[]).gsub(/&nbsp;/i, ' ').squish
  end

  def self.excluding_blocks(user)
    people = user.blocks.map{|b| b.person_id}
    scope = scoped

    if people.any?
      scope = scope.where("posts.author_id NOT IN (?)", people)
    end

    scope
  end

  def self.excluding_hidden_shareables(user)
    scope = scoped
    if user.has_hidden_shareables_of_type?
      scope = scope.where('posts.id NOT IN (?)', user.hidden_shareables["#{self.base_class}"])
    end
    scope
  end

  def self.excluding_hidden_content(user)
    excluding_blocks(user).excluding_hidden_shareables(user)
  end

  def self.for_a_stream(max_time, order, user=nil)
    scope = self.for_visible_shareable_sql(max_time, order).
      includes_for_a_stream

    scope = scope.excluding_hidden_content(user) if user.present?

    scope
  end

  def reshare_for(user)
    return unless user
    reshares.where(:author_id => user.person.id).first
  end

  def participation_for(user)
    return unless user
    participations.where(:author_id => user.person.id).first
  end

  def like_for(user)
    return unless user
    likes.where(:author_id => user.person.id).first
  end

  #############

  def self.diaspora_initialize(params)
    new_post = self.new params.to_hash
    new_post.author = params[:author]
    new_post.public = params[:public] if params[:public]
    new_post.parent_guid = params[:parent_guid]
    new_post.diaspora_handle = new_post.author.diaspora_handle
    new_post
  end

  # @return Returns true if this Post will accept updates (i.e. updates to the caption of a photo).
  def mutable?
    false
  end

  def activity_streams?
    false
  end

  def notify_source!
    Notifications::Remixed.create_from_post(self) if self.parent.present?
  end

  def comment_email_subject
    I18n.t('notifier.a_post_you_shared')
  end

  def screenshot!
    return false unless self.persisted?
    frame_url = "https://www.makr.io/posts/#{self.guid}/frame"
    #maybe want to configure tmp directory,
    file = Screencap::Fetcher.new(frame_url).fetch(:div => '.canvas-frame:first', :output => Rails.root.join('tmp', "#{self.guid}.jpg"))
    self.screenshot.store!(file)
    self.save!
  end

  def re_screenshot!
    self.remove_screenshot = true
    self.save!
    self.screenshot!
  end

  def screenshot_url
    screenshot.url
  end

  def nsfw
    self.author.profile.nsfw?
  end

  def self.find_by_guid_or_id_with_user(id, user=nil)
    key = id.to_s.length <= 8 ? :id : :guid
    post = if user
             user.find_visible_shareable_by_id(Post, id, :key => key)
           else
             Post.where(key => id, :public => true).includes(:author, :comments => :author).first
           end

    post || raise(ActiveRecord::RecordNotFound.new("could not find a post with id #{id}"))
  end
end
