require 'active_record'
require 'dotenv/load'

ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: ENV['DB_HOST'] || 'localhost',
  port: ENV['DB_PORT'] || 5432,
  database: ENV['DB_NAME'] || 'vercel_scraper',
  username: ENV['DB_USERNAME'],
  password: ENV['DB_PASSWORD']
)

# Load models
require_relative '../models/repository'
require_relative '../models/pull_request'
require_relative '../models/review'
require_relative '../models/user'