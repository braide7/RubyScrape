require 'dotenv/load'
require_relative 'config/database'
require_relative 'lib/github_scraper'

# Run migrations
def run_migrations
  require_relative 'db/migrate/create_tables'
  CreateTables.new.change
rescue ActiveRecord::StatementInvalid => e
  puts "Migration already applied or error: #{e.message}"
end

# Main execution
if __FILE__ == $0
  # Check required environment variables
  required_vars = ['GITHUB_TOKEN', 'DB_USERNAME', 'DB_PASSWORD']
  missing_vars = required_vars.select { |var| ENV[var].nil? || ENV[var].empty? }
  
  if missing_vars.any?
    puts "Missing required environment variables: #{missing_vars.join(', ')}"
    puts "Please set these in your .env file"
    exit 1
  end
  
  # Setup database
  run_migrations
  
  # Start scraping
  scraper = GitHubScraper.new(max_threads: 10)
  puts scraper.instance_variable_get(:@client).rate_limit_status
  scraper.scrape_all
  
end

