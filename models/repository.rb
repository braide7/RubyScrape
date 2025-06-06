class Repository < ActiveRecord::Base
  has_many :pull_requests, dependent: :destroy
  has_many :reviews, through: :pull_requests

  validates :name, presence: true
  validates :url, presence: true
  validates :github_id, presence: true, uniqueness: true
end