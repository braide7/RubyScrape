class PullRequest < ActiveRecord::Base
  belongs_to :repository
  belongs_to :author, class_name: 'User', optional: true
  has_many :reviews, dependent: :destroy

  validates :number, presence: true, uniqueness: { scope: :repository_id }
  validates :github_id, presence: true, uniqueness: true
  
end