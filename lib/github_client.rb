require 'net/http'
require 'uri'
require 'json'
require 'time'

class GitHubClient
  BASE_URL = 'https://api.github.com'
  GRAPHQL_URL = 'https://api.github.com/graphql'
  
  def initialize(token)
    @token = token
    @graphql_rate_limit = {
      remaining: 5000,
      reset_at: Time.now + 3600,
      cost: 0
    }
  end

  #calls graphql_request for repositories, returns response or handles errors
  def get_repositories(org, after_cursor = nil)
    query = build_repositories_query(org, after_cursor)
    response = graphql_request(query)
    
    if response['data'] && response['data']['organization']
      response['data']['organization']['repositories']
    else
      handle_graphql_errors(response)
    end
  end
 #calls graphql_request for requests and reviews, returns response or handles errors
  def get_pull_requests_with_reviews(owner, repo, after_cursor = nil)
    query = build_pull_requests_query(owner, repo, after_cursor)
    response = graphql_request(query)
    
    if response['data'] && response['data']['repository']
      response['data']['repository']['pullRequests']
    else
      handle_graphql_errors(response)
    end
  end

  # Method to check current rate limit status
  def rate_limit_status
    query = <<~GRAPHQL
      {
        rateLimit {
          cost
          remaining
          resetAt
          limit
        }
      }
    GRAPHQL
    
    response = graphql_request(query, skip_rate_limit_check: true)
    if response['data'] && response['data']['rateLimit']
      response['data']['rateLimit']
    end
  end

  private

  #query to get repositories and users taking in org and optional cursor
  def build_repositories_query(org, after_cursor = nil)
    after_clause = after_cursor ? ", after: \"#{after_cursor}\"" : ""
    
    <<~GRAPHQL
      {
        rateLimit {
          cost
          remaining
          resetAt
        }
        organization(login: "#{org}") {
          repositories(first: 100, privacy: PUBLIC#{after_clause}) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              name
              url
              isPrivate
              isArchived
            }
          }
        }
      }
    GRAPHQL
  end

  #query to get pull requests, reviews, and users
  def build_pull_requests_query(owner, repo, after_cursor = nil)
    after_clause = after_cursor ? ", after: \"#{after_cursor}\"" : ""
    
    <<~GRAPHQL
      {
        rateLimit {
          cost
          remaining
          resetAt
        }
        repository(owner: "#{owner}", name: "#{repo}") {
          pullRequests(first: 100, states: [OPEN, CLOSED, MERGED]#{after_clause}) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              number
              title
              updatedAt
              closedAt
              mergedAt
              author {
                login
              }
              additions
              deletions
              changedFiles
              commits {
                totalCount
              }
              reviews(first: 100) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  id
                  author {
                    login
                  }
                  state
                  submittedAt
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end
  #reusable graphql request with error handling
  def graphql_request(query, attempt = 1, skip_rate_limit_check: false)
    check_graphql_rate_limit unless skip_rate_limit_check
    
    uri = URI(GRAPHQL_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 60
    http.read_timeout = 90
    
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Content-Type'] = 'application/json'
    request.body = { query: query }.to_json
    
    response = http.request(request)
    
    # Handle server errors with exponential backoff
    if server_error?(response.code.to_i)
      return handle_server_error(query, response, attempt)
    end
    
    parsed_response = JSON.parse(response.body)
    update_graphql_rate_limit_info(parsed_response)
    
    parsed_response
    
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    puts "Network timeout: #{e.message}. Attempt #{attempt}"
    return handle_network_error(query, attempt, e)
  rescue JSON::ParserError => e
    puts "JSON parsing error: #{e.message}. Attempt #{attempt}"
    return handle_json_error(query, attempt, e)
  rescue => e
    puts "Unexpected error: #{e.message}. Attempt #{attempt}"
    return handle_unexpected_error(query, attempt, e)
  end

  # Check if we have enough points remaining for a typical query
  def check_graphql_rate_limit
    
    min_points_needed = 50 # Conservative buffer
    
    if @graphql_rate_limit[:remaining] <= min_points_needed
      #adds 60 seconds to wait time, ensures result is not negative
      sleep_time = [@graphql_rate_limit[:reset_at] - Time.now + 60, 0].max
      if sleep_time > 0
        puts "GraphQL rate limit low (#{@graphql_rate_limit[:remaining]} points remaining). Sleeping for #{sleep_time.to_i} seconds..."
        sleep(sleep_time)

        # Reset rate limit tracking after waiting
        @graphql_rate_limit[:remaining] = 5000
        @graphql_rate_limit[:reset_at] = Time.now + 3600
      end
    end
  end

  def update_graphql_rate_limit_info(response)
    if response['data'] && response['data']['rateLimit']
      rate_limit = response['data']['rateLimit']
      @graphql_rate_limit[:cost] = rate_limit['cost']
      @graphql_rate_limit[:remaining] = rate_limit['remaining']
      @graphql_rate_limit[:reset_at] = Time.parse(rate_limit['resetAt'])
      
      puts "GraphQL Query Cost: #{rate_limit['cost']} points, Remaining: #{rate_limit['remaining']} points"
      
    end
  end

  ##ERROR HANDLING##

  #helper function to match server error codes
  def server_error?(status_code)
    [500, 502, 503, 504].include?(status_code)
  end

  def handle_server_error(query, response, attempt)
    max_attempts = 10
    
    if attempt > max_attempts
      puts "Max retry attempts (#{max_attempts}) exceeded for server error #{status_code}"
      raise StandardError, "Server error #{response.code.to_i}: Max retries exceeded"
    end
    
    delay = calculate_exponential_delay(attempt)
    puts "Server error #{response.message} #{response.code.to_i} on attempt #{attempt}/#{max_attempts}. Retrying in #{delay} seconds..."
    sleep(delay)
    
    graphql_request(query, attempt + 1)
  end

  def handle_network_error(query, attempt, error)
    max_attempts = 10
    
    if attempt > max_attempts
      puts "Max retry attempts (#{max_attempts}) exceeded for network error: #{error.message}"
      raise error
    end
    
    delay = calculate_exponential_delay(attempt)
    puts "Network error on attempt #{attempt}/#{max_attempts}. Retrying in #{delay} seconds..."
    sleep(delay)
    
    graphql_request(query, attempt + 1)
  end

  def handle_json_error(query, attempt, error)
    max_attempts = 10
    
    if attempt > max_attempts
      puts "Max retry attempts (#{max_attempts}) exceeded for JSON parsing error: #{error.message}"
      return { 'errors' => ['Invalid JSON response after retries'] }
    end
    
    delay = calculate_exponential_delay(attempt)
    puts "JSON parsing error on attempt #{attempt}/#{max_attempts}. Retrying in #{delay} seconds..."
    sleep(delay)
    
    graphql_request(query, attempt + 1)
  end

  def handle_unexpected_error(query, attempt, error)
    max_attempts = 10
    
    if attempt > max_attempts
      puts "Max retry attempts (#{max_attempts}) exceeded for unexpected error: #{error.message}"
      raise error
    end
    
    delay = calculate_exponential_delay(attempt)
    puts "Unexpected error on attempt #{attempt}/#{max_attempts}. Retrying in #{delay} seconds..."
    sleep(delay)
    
    graphql_request(query, attempt + 1)
  end

  def handle_graphql_errors(response)
    if response['errors']
      puts "GraphQL Errors: #{response['errors']}"
      
      # Check for secondary rate limits (abuse detection)
      abuse_error = response['errors'].find do |error|
        error['message']&.include?('abuse') || 
        error['message']&.include?('secondary rate limit')
      end
      
      if abuse_error
        puts "Secondary rate limit (abuse detection) triggered. Waiting 3 minutes..."
        sleep(180)
        return nil
      end

      # Check for specific rate limit errors
      rate_limit_error = response['errors'].find do |error| 
        error['type'] == 'RATE_LIMITED' || 
        error['message']&.include?('rate limit') ||
        error['message']&.include?('API rate limit exceeded')
      end
      
      if rate_limit_error
        puts "GraphQL rate limit exceeded. Waiting 1 hour..."
        sleep(3600)
        return nil
      end
    end
    
    raise StandardError, "API request failed: #{response}"
  end

  def calculate_exponential_delay(attempt)
    # Base delay of 3 seconds
    base_delay = 3
    exponential_delay = base_delay * (2 ** (attempt - 1))
    
    # Cap maximum delay at 5 minutes
    [exponential_delay, 300].min
  end
end