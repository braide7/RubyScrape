require_relative 'github_client'
require 'concurrent-ruby'

class GitHubScraper
  def initialize(max_threads: 10)  
    @client = GitHubClient.new(ENV['GITHUB_TOKEN'])
    @organization = 'vercel'
    @max_threads = max_threads
    @thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: @max_threads,
      max_queue: 50,
      fallback_policy: :caller_runs
    )
    # Rate limiting controls
    @request_semaphore = Concurrent::Semaphore.new(10) # Max 10 concurrent API requests
    @last_request_time = Concurrent::AtomicReference.new(Time.now)
    @rate_limit_delay = 1 # Base delay between requests in seconds
    @exponential_backoff = Concurrent::AtomicReference.new(1.0)
  end

  def scrape_all
    puts "Starting threaded scrape of #{@organization} organization with #{@max_threads} threads..."
    
    scrape_repositories
    scrape_pull_requests_and_reviews_threaded
    
    
    puts "Scraping completed!"
  #shuts down threads 
  ensure
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(30)
  end

  private

  def rate_limited_request(&block)
    @request_semaphore.acquire
    
    begin
      # Ensure minimum delay between requests
      current_backoff = @exponential_backoff.get
      sleep_time = [@rate_limit_delay * current_backoff, 0.1].max
      
      time_since_last = Time.now - @last_request_time.get
      if time_since_last < sleep_time
        sleep(sleep_time - time_since_last)
      end
      
      @last_request_time.set(Time.now)
      
      result = yield
      
      # Reset backoff on successful request
      @exponential_backoff.set(1.0)
      
      result
    rescue => e
      if secondary_rate_limit_error?(e)
        handle_secondary_rate_limit(e)
        # Retry the request after backoff
        retry
      else
        raise e
      end
    ensure
      @request_semaphore.release
    end
  end

  def secondary_rate_limit_error?(error)
    # Check if error indicates secondary rate limiting
    error.message.include?('secondary rate limit') ||
    error.message.include?('abuse detection') ||
    (error.respond_to?(:response) && error.response&.status == 403)
  end

  def handle_secondary_rate_limit(error)
    current_backoff = @exponential_backoff.get
    new_backoff = [current_backoff * 2, 60.0].min # Cap at 60 seconds
    @exponential_backoff.set(new_backoff)
    
    sleep_time = new_backoff + rand(5) # Add jitter
    puts "Secondary rate limit hit. Backing off for #{sleep_time.round(2)} seconds..."
    sleep(sleep_time)
  end

  def scrape_repositories
    puts "Fetching repositories..."
    
    has_next_page = true
    after_cursor = nil
    
    while has_next_page
      result = rate_limited_request do
        @client.get_repositories(@organization, after_cursor)
      end
      
      next unless result
      
      result['nodes'].each do |repo_data|
        save_repository(repo_data)
      end
      
      has_next_page = result['pageInfo']['hasNextPage']
      after_cursor = result['pageInfo']['endCursor']
      
      puts "Processed batch of repositories. Has next page: #{has_next_page}"
    end
  end

  def scrape_pull_requests_and_reviews_threaded
    puts "Fetching pull requests and reviews with threading..."
    
    repositories = Repository.all.to_a
    puts "Processing #{repositories.count} repositories across #{@max_threads} threads"

    # Filter repositories that need processing
    repositories_to_process = filter_repositories_needing_update(repositories)
    puts "Filtered down to #{repositories_to_process.count} repositories that need updates"

    if repositories_to_process.count > 0
      # Use concurrent futures to track completion
      futures = repositories_to_process.map do |repository|
        Concurrent::Future.execute(executor: @thread_pool) do
          process_repository_pull_requests(repository)
        end
      end
      
      # Wait for all futures to complete and handle any errors
      completed = 0
      futures.each_with_index do |future, index|
        repository = repositories_to_process[index]
        begin
          future.wait
          # Update timestamp only after successful processing of ALL PRs/reviews for this repository
          repository.update!(last_successful_run: Time.current)
          puts "Updated last successful run for #{repository.name}"
          completed += 1
          puts "Completed #{completed}/#{repositories_to_process.count} repositories"
        rescue => e
          puts "Error processing repository #{repositories_to_process[index].name}: #{e.message}"
        end
      end
    end

    puts "Finished processing all repositories"
  end

  def filter_repositories_needing_update(repositories)
  repositories.select do |repository|
    # Skip if we've never run before (process all repos)
    next true if repository.last_successful_run.nil?
    
    begin

      last_github_update = repository.github_last_updated_at
      last_run = repository.last_successful_run

      # Process if repository has been updated since last successful run
      needs_update = last_github_update > last_run
      
      unless needs_update
        puts "Skipping #{repository.name} - no updates since last run"
      end
      
      needs_update
    rescue => e
      puts "Error checking update status for #{repository.name}: #{e.message}"
      true # Process on error to be safe
    end
  end
end

  def process_repository_pull_requests(repository)
    puts "[Thread #{Thread.current.object_id}] Processing repository: #{repository.name}"
    
    has_next_page = true
    after_cursor = nil
    processed_count = 0
    early_termination = false
    
    while has_next_page && !early_termination
      result = rate_limited_request do
        @client.get_pull_requests_with_reviews(@organization, repository.name, after_cursor)
      end
        next unless result
      
      result['nodes'].each do |pr_data|
        pr_updated_at = Time.parse(pr_data['updatedAt'])
        
        # Early termination: Since PRs are ordered by updated_at DESC,
        # if we encounter a PR older than last run, we can stop processing
        if repository.last_successful_run && pr_updated_at <= repository.last_successful_run
          puts "[Thread #{Thread.current.object_id}] Early termination for #{repository.name} - reached PRs older than last run (#{repository.last_successful_run})"
          early_termination = true
          break
        end
        
        save_pull_request(repository, pr_data)
        processed_count += 1
      end
      
      # Only continue pagination if we haven't hit early termination
      if !early_termination
        has_next_page = result['pageInfo']['hasNextPage']
        after_cursor = result['pageInfo']['endCursor']
        
        puts "[Thread #{Thread.current.object_id}] Processed #{processed_count} updated PRs for #{repository.name}. Has next page: #{has_next_page}"
      end

      # Add small delay between pages for the same repository
      sleep(0.5) if has_next_page
    end
    
    if early_termination
      puts "[Thread #{Thread.current.object_id}] Finished processing #{repository.name} - #{processed_count} PRs processed (early termination)"
    else
      puts "[Thread #{Thread.current.object_id}] Finished processing #{repository.name} - #{processed_count} PRs processed (complete)"
    end
  rescue => e
    puts "[Thread #{Thread.current.object_id}] Error processing repository #{repository.name}: #{e.message}"
    raise e # Re-raise to be caught by the future
  end

  def save_repository(repo_data)
    # Thread-safe database operations with retry logic
    ActiveRecord::Base.connection_pool.with_connection do
      Repository.find_or_create_by(github_id: repo_data['id']) do |repo|
        repo.name = repo_data['name']
        repo.url = repo_data['url']
        repo.private = repo_data['isPrivate']
        repo.archived = repo_data['isArchived']
        repo.github_last_updated_at = repo_data['updatedAt']
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # Handle race condition where another thread created the record
    retry
  rescue => e
    puts "Error saving repository #{repo_data['name']}: #{e.message}"
  end

  def save_pull_request(repository, pr_data)
    ActiveRecord::Base.connection_pool.with_connection do
      pr = PullRequest.find_or_initialize_by(github_id: pr_data['id'])
      
      # Find or create author
      author = nil
      if pr_data['author'] && pr_data['author']['login']
        author = find_or_create_user_thread_safe(pr_data['author']['login'])
      end
      
      pr.assign_attributes(
        repository: repository,
        author: author,
        number: pr_data['number'],
        title: pr_data['title'],
        updated_at_github: Time.parse(pr_data['updatedAt']),
        closed_at: pr_data['closedAt'] ? Time.parse(pr_data['closedAt']) : nil,
        merged_at: pr_data['mergedAt'] ? Time.parse(pr_data['mergedAt']) : nil,
        additions: pr_data['additions'],
        deletions: pr_data['deletions'],
        changed_files: pr_data['changedFiles'],
        commits_count: pr_data['commits']['totalCount']
      )
      
      pr.save!
      
      # Save reviews
      pr_data['reviews']['nodes'].each do |review_data|
        save_review(pr, review_data)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # Handle race condition
    retry
  rescue => e
    puts "Error saving pull request #{pr_data['number']}: #{e.message}"
  end

  def save_review(pull_request, review_data)
    review = Review.find_or_initialize_by(github_id: review_data['id'])
    
    # Find or create author
    author = nil
    if review_data['author'] && review_data['author']['login']
      author = find_or_create_user_thread_safe(review_data['author']['login'])
    end
    
    review.assign_attributes(
      pull_request: pull_request,
      author: author,
      state: review_data['state'],
      submitted_at: review_data['submittedAt'] ? Time.parse(review_data['submittedAt']) : nil
    )
    
    review.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue => e
    puts "Error saving review #{review_data['id']}: #{e.message}"
  end

  def find_or_create_user_thread_safe(login)
    # Thread-safe user creation with mutex for critical section
    @user_mutex ||= Mutex.new
    
    # First try to find existing user (read operation, no lock needed)
    user = User.find_by(login: login)
    return user if user
    
    # If not found, use mutex to safely create
    @user_mutex.synchronize do
      # Double-check after acquiring lock (another thread might have created it)
      User.find_by(login: login) || User.create!(login: login)
    end
  rescue ActiveRecord::RecordNotUnique
    # Another thread created it between our checks
    User.find_by(login: login)
  rescue => e
    puts "Error saving user #{login}: #{e.message}"
    nil
  end
end