class User < ActiveRecord::Base
  has_many :authored_pull_requests, class_name: 'PullRequest', foreign_key: 'author_id'
  has_many :authored_reviews, class_name: 'Review', foreign_key: 'author_id'

  validates :login, presence: true, uniqueness: true
  
end