# GitHub Vercel Organization Scraper

## Overview

This project uses Ruby to scrape GitHub data via the GraphQL API. It leverages multithreading to significantly reduce processing time and error handling to ensure stability during network or API disruptions. Data is stored in a PostgreSQL database.

## Prerequisites

- Ruby 3.0 or higher
- PostgreSQL 12 or higher
- GitHub Personal Access Token
- Bundler for dependency management

## Setup Instructions

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/braide7/RubyScrape.git
   ```
   ```bash
   cd RubyScrape
   ```
2. Install dependencies:
   ```bash
   bundle install
   ```

3. Create PostgreSQL database:
   ```sql
   CREATE DATABASE github_scraper;
   ```
4. Get a GitHub Personal Access Token with appropriate permissions:
   - Go to GitHub Settings > Developer settings > Personal access tokens
   - Create a token

5. Create .env and fill in your values:
   - GitHub API Token 
   ```bash
   GITHUB_TOKEN=_yourgithubtokenhere
   ```
    - PostgreSQL Database Configuration
   ```bash
   DB_HOST=localhost
   DB_PORT=5432
   DB_NAME=github_scraper_db
   DB_USERNAME=your_db_user
   DB_PASSWORD=your_db_password
   ```

6. Run the scraper:
   ```bash
   ruby main.rb
   ```

## Features

- **Multithreaded Processing**: Utilizes Ruby's threading to parallelize API requests, drastically reducing runtime for large datasets.

- **Comprehensive Error Handling**: Robustly manages network failures, API errors, and rate limits with retry logic and detailed logging.

- **GraphQL Optimization**: Minimizes API calls with efficient GraphQL queries for faster, cost-effective data retrieval.

- **Pagination Support**: Seamlessly handles large datasets with robust pagination.

- **Relational Database**: Stores data in PostgreSQL with foreign key relationships for repositories, pull requests, reviews, and users.

- **Rate Limit Management**: Automatically detects and respects GitHub API rate limits, pausing and resuming as needed.

## Database Schema

- **repositories**: Stores repository data
- **pull_requests**: Stores PR information
- **reviews**: Stores PR review data
- **users**: Stores unique GitHub users

## API Limits

The scraper respects GitHub's GraphQL API limits:
- 5000 points per hour
- Automatic rate limit detection and waiting
- Efficient batching of queries