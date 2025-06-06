class Review < ActiveRecord::Base
  belongs_to :pull_request
  belongs_to :author, class_name: 'User', optional: true

  validates :github_id, presence: true, uniqueness: true
  
end