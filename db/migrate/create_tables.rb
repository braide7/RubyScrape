require 'active_record'

class CreateTables < ActiveRecord::Migration[7.0]
  def change
    # create tables / indexes if they don't exist
    create_table :users, if_not_exists: true  do |t|
      t.string :login, null: false
      t.timestamps
    end

    create_table :repositories, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :private, default: false
      t.boolean :archived, default: false
      t.string :github_id, null: false
      t.timestamps
    end

    create_table :pull_requests, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :author, null: true, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :title
      t.datetime :updated_at_github
      t.datetime :closed_at
      t.datetime :merged_at
      t.integer :additions
      t.integer :deletions
      t.integer :changed_files
      t.integer :commits_count
      t.string :github_id, null: false
      t.timestamps
    end

    create_table :reviews, if_not_exists: true do |t|
      t.references :pull_request, null: false, foreign_key: true
      t.references :author, null: true, foreign_key: { to_table: :users }
      t.string :state
      t.datetime :submitted_at
      t.string :github_id, null: false
      t.timestamps
    end

    # Indexes for performance
    add_index :repositories, :github_id, unique: true unless index_exists?(:repositories, :github_id)
    add_index :pull_requests, [:repository_id, :number], unique: true unless index_exists?(:pull_requests, [:repository_id, :number])
    add_index :pull_requests, :github_id, unique: true unless index_exists?(:pull_requests, :github_id)
    add_index :pull_requests, :author_id unless index_exists?(:pull_requests, :author_id)
    add_index :reviews, :github_id, unique: true unless index_exists?(:reviews, :github_id,)
    add_index :reviews, :author_id unless index_exists?(:reviews, :author_id)
    add_index :users, :login, unique: true unless index_exists?(:users, :login)
  end
end