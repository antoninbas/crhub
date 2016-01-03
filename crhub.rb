#!/usr/bin/env ruby

# Copyright 2015-present Antonin Bas
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# Antonin Bas (antonin.bas@gmail.com)
#
#

require 'sinatra/base'
require 'json'
require 'octokit'
require 'sqlite3'
require 'thread'
require 'set'
require 'parseconfig'

if not ENV.include?("GITHUB_PERSONAL_TOKEN")
  puts "You need to define the 'GITHUB_PERSONAL_TOKEN' env variable"
  puts "See README.md for more information"
  exit(1)
end
$ACCESS_TOKEN = ENV["GITHUB_PERSONAL_TOKEN"]

if ARGV.length != 1
  puts "Error, crhub.rb takes exactly one argument (.conf file)"
  puts "Usage: ruby crhub.rb [crhub.conf]"
  exit(1)
end
config_file = ARGV[0]
if not File.file?(config_file)
  puts  "File '#{config_file}' does not exist"
  exit(1)
end

puts "Using #{config_file} as configuration file"

config = ParseConfig.new(config_file)

class RepoConfig
  attr_reader :with_self_assign
  attr_reader :users_bypass

  def initialize()
    @with_self_assign = true
    @users_bypass = Set.new
  end

  def load_config(config)
    if not config["with_self_assign"].nil?
      @with_self_assign = (config["with_self_assign"] == "true")
    end
    if not config["users_bypass"].nil?
      @users_bypass = config["users_bypass"].split()
      @users_bypass = @users_bypass.to_set
    end
  end
end

class CrhubConfig
  def initialize()
    @default_repo_config = RepoConfig.new()

    @repos_raw = []

    @sinatra_config = {
      :bind => '0.0.0.0',
      :port => 4567,
      :environment => 'production'
    }

    @general_config = {
      :db_path => 'test.db'
    }

    @repo_configs = {}
  end

  def get_sinatra_config()
    return @sinatra_config
  end

  def get_repo_configs()
    return @repo_configs
  end

  def get_raw_repo_names()
    return @repos_raw
  end

  def get_db_path()
    return @general_config[:db_path]
  end

  def easy_load(config, name, target)
    if not config[name].nil?
      config[name].each do |key, value|
        target[key.to_sym] = value
      end
    end
  end

  def load_config(config)
    if not config['repo-default'].nil?
      @default_repo_config.load_config(config['repo-default'])
    end

    easy_load(config, 'general', @general_config)
    easy_load(config, 'sinatra', @sinatra_config)

    config.get_groups().each do |group_name|
      if group_name.start_with?('repo:')
        repo_name = group_name.slice(5..-1)
        @repos_raw.push(repo_name)
        # repo_name = sanitize_repo_name(repo_name)
        repo_config = @default_repo_config.clone()
        repo_config.load_config(config[group_name])
        @repo_configs[repo_name] = repo_config
      end
    end
  end
end

$config = CrhubConfig.new()
$config.load_config(config)

class CrhubDB
  def initialize(repos, db_name)
    @repos = repos
    @db = SQLite3::Database.new db_name
    create_tables()
  end

  def sanitize_repo_name(repo)
    return repo.sub('/', '---').gsub("-", "_")
  end

  def create_tables()
    @repos.each do |repo|
      repo = sanitize_repo_name(repo)
      # sha used to be "unique", but 2 PRs can be created with exactly the same diff / sha
      s = "create table if not exists #{repo} (
             number integer primary key,
             id int unique,
             title text,
             user_id int,
             user_login text,
             assignee_id int,
             assignee_login text,
             sha text,
             target_branch text
           )"
      rows = @db.execute(s)
      s = "create table if not exists #{repo}__reviews_ (
             number int,
             user_id int,
             score int
           )"
      rows = @db.execute(s)
      s = "create unique index if not exists #{repo}__reviews_idx_
       on #{repo}__reviews_ (number, user_id)"
      rows = @db.execute(s)
    end
  end

  def update_pr(repo, number, id, title, user_id, user_login,
                assignee_id, assignee_login, sha, target_branch)
    repo = sanitize_repo_name(repo)
    query = "select * from #{repo} where number = ?"
    rows = @db.execute(query, number)
    if rows.length == 0
      query = "insert into #{repo} (number, id, title, user_id, user_login, assignee_id, assignee_login, sha, target_branch)
               values (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      @db.execute(query, [number, id, title, user_id, user_login, assignee_id, assignee_login, sha, target_branch])
      return true
    end
    raise "Corrupted DB" unless rows.length == 1
    row = rows[0]
    raise "Corrupted DB" unless row[1] == id
    raise "Corrupted DB" unless row[2] == title
    raise "Corrupted DB" unless row[3] == user_id
    raise "Corrupted DB" unless row[4] == user_login
    if row[5] != assignee_id
      query = "replace into #{repo} (number, id, title, user_id, user_login, assignee_id, assignee_login, sha, target_branch)
               values (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      @db.execute(query, [number, id, title, user_id, user_login, assignee_id, assignee_login, sha, target_branch])
      return true
    end
    return false
  end

  def add_review(repo, number, user_id, score)
    repo = sanitize_repo_name(repo)
    query = "insert or replace into #{repo}__reviews_ (number, user_id, score)
             values (?, ?, ?)"
    @db.execute(query, [number, user_id, score])
  end

  def get_status(repo, number)
    repo = sanitize_repo_name(repo)
    repo_reviews = "#{repo}__reviews_"
    query = "select score from #{repo}, #{repo_reviews}
             where #{repo}.number = ? and #{repo_reviews}.number = ? and #{repo}.assignee_id = #{repo_reviews}.user_id"
    rows = @db.execute(query, [number, number])
    if rows.length == 0
      return 0
    end
    return rows[0][0]
  end

  def get_by_attr(repo, number, attr)
    repo = sanitize_repo_name(repo)
    query = "select #{attr} from #{repo}
             where #{repo}.number = ?"
    rows = @db.execute(query, number)
    if rows.length == 0
      return nil
    end
    return rows[0][0]
  end

  def get_branch(repo, number)
    return get_by_attr(repo, number, 'target_branch')
  end

  def get_user_login(repo, number)
    return get_by_attr(repo, number, 'user_login')
  end

  def is_self_assigned(repo, number)
    repo = sanitize_repo_name(repo)
    query = "select user_id, assignee_id from #{repo}
             where #{repo}.number = ?"
    rows = @db.execute(query, number)
    if rows.length == 0
      return false
    end
    return rows[0][0] == rows[0][1]
  end

  def get_pr_entry(repo, number)
    repo = sanitize_repo_name(repo)
    query = "select * from #{repo} where number = ?"
    rows = @db.execute(query, number)
    if rows.length == 0
      return nil
    end
    return rows[0]
  end

  def self.pr_entry_get_sha(entry)
    return entry[7]
  end

  def show_prs(repo)
    repo = sanitize_repo_name(repo)
    query = "select * from #{repo}"
    @db.execute(query) do |row|
      puts row
    end
  end

  private :sanitize_repo_name, :create_tables, :get_by_attr
end

class CrhubState
  def initialize(config)
    @config = config
    @repo_configs = config.get_repo_configs()
    @repos = config.get_raw_repo_names()
    @the_db = CrhubDB.new(@repos, config.get_db_path())

    @sync = {}
    @repos.each do |repo|
      repo_state = {}
      repo_state[:sema] = Mutex.new
      repo_state[:busy] = Set.new
      @sync[repo] = repo_state
    end
  end

  def get_score(comment_body)
    score = nil
    case comment_body
    when "+1"
      score = 1
    when "-1"
      score = -1
    end
    return score
  end

  def set_pr_status(repo, number, sha, status)
    target_branch = @the_db.get_branch(repo, number)
    if target_branch != "master"
      return
    end
    options = {}
    options[:context] = "crhub"
    options[:description] = "checks code review status"
    client = Octokit::Client.new(:access_token => $ACCESS_TOKEN)
    client.create_status(repo, sha, status, options)
  end

  def repo_name_from_pr(pr)
    return pr['base']['repo']['full_name']
  end

  def push_status(repo, number, sha)
    user_login = @the_db.get_user_login(repo, number)
    users_bypass = @repo_configs[repo].users_bypass
    if users_bypass.include?(user_login)
      puts "User #{user_login} is a bypass user for repo #{repo}"
      puts "Status is therefore 'success'"
      set_pr_status(repo, number, sha, "success")
      return
    end
    with_self_assign = @repo_configs[repo].with_self_assign
    if not with_self_assign and @the_db.is_self_assigned(repo, number)
      puts "Self-assign is disabled for repo #{repo}, status is 'failure'"
      set_pr_status(repo, number, sha, "failure")
      return
    end
    score = @the_db.get_status(repo, number)
    if score > 0
      set_pr_status(repo, number, sha, "success")
    else
      set_pr_status(repo, number, sha, "failure")
    end
  end

  def request_access(repo, pr_number)
    repo_state = @sync[repo]
    repo_state[:sema].lock()
    while repo_state[:busy].include?(pr_number)
      repo_state[:sema].unlock()
      sleep(0)
      repo_state[:sema].lock()
    end
    repo_state[:busy].add(pr_number)
    repo_state[:sema].unlock()
  end

  def release_access(repo, pr_number)
    repo_state = @sync[repo]
    repo_state[:sema].synchronize {
      repo_state[:busy].delete(pr_number)
    }
  end

  def process_pr(pr)
    repo = repo_name_from_pr(pr)
    set_pr_status(repo, pr['number'], pr['head']['sha'], "pending")
    entry = [pr['number'], pr['id'], pr['title'],
             pr['user']['id'], pr['user']['login']]
    score = 0
    if pr['assignee']
      entry += [pr['assignee']['id'], pr['assignee']['login']]
    else
      # no assignee yet
      entry += [nil, nil]
    end
    entry += [pr['head']['sha']]
    entry += [pr['base']['ref']] # target branch
    # puts entry.join(", ")
    request_access(repo, pr['number'])
    changed = @the_db.update_pr(repo, *entry)
    push_status(repo, pr['number'], pr['head']['sha'])
    release_access(repo, pr['number'])
  end

  def process_pr_comment(repo, issue, comment)
    # necessary?
    request_access(repo, issue['number'])
    db_entry = @the_db.get_pr_entry(repo, issue['number'])
    if not db_entry
      puts "No PR matching comment, ignoring"
      release_access(repo, issue['number'])
      return
    end
    sha = CrhubDB.pr_entry_get_sha(db_entry)
    set_pr_status(repo, issue['number'], sha, "pending")
    score = get_score(comment['body'])
    if score
      @the_db.add_review(repo, issue['number'], comment["user"]["id"], score)
    end
    push_status(repo, issue['number'], sha)
    release_access(repo, issue['number'])
  end
end

class Crhub < Sinatra::Base
  def initialize()
    super()
    # TODO(antonin): put this in configure (as setting) and remove this method?
    @state = CrhubState.new($config)
  end

  configure do
    set :environment, "production"
    $config.get_sinatra_config().each do |key, value|
      set key, value
    end
    # set :bind, '0.0.0.0'
  end

  # for testing only
  get '/' do
    "Hello World!"
  end

  post '/codereview' do
    @payload = JSON.parse(request.body.read)

    case request.env['HTTP_X_GITHUB_EVENT']
    when "pull_request"
      action = @payload["action"]
      case action
      when "opened"
        process_pull_request_opened(@payload["pull_request"])
      when "reopened"
        process_pull_request_opened(@payload["pull_request"])
      when "closed"
        process_pull_request_closed(@payload["pull_request"])
      when "labeled"
        process_pull_request_labeled(@payload["pull_request"],
                                     @payload["label"])
      when "unlabeled"
        process_pull_request_unlabeled(@payload["pull_request"],
                                       @payload["label"])
      when "assigned"
        process_pull_request_assigned(@payload["pull_request"])
      when "unassigned"
        process_pull_request_unassigned(@payload["pull_request"])
      when "synchronize"
        process_pull_request_synchronize(@payload["pull_request"])
      end
    when "status"
      process_status()
    when "commit_comment"
      process_commit_comment()
    when "issue_comment"
      process_issue_comment(@payload["repository"]["full_name"],
                            @payload["issue"], @payload["comment"])
    when "pull_request_review_comment"
      process_pull_request_review_comment()
    end
  end

  helpers do
    def process_pull_request_opened(pull_request)
      puts "Opened PR #{pull_request['title']}"
      @state.process_pr(pull_request)
    end

    def process_pull_request_closed(pull_request)
      puts "Closed PR #{pull_request['title']}"
      # do nothing for now
    end

    def process_pull_request_labeled(pull_request, label)
      puts "Labeled PR #{pull_request['title']} with #{label['name']}"
      # do nothing for now
    end

    def process_pull_request_unlabeled(pull_request, label)
      puts "Unlabeled PR #{pull_request['title']}: removed #{label['name']}"
      # do nothing for now
    end

    def process_pull_request_assigned(pull_request)
      puts "Assigned PR #{pull_request['title']}"
      @state.process_pr(pull_request)
    end

    def process_pull_request_unassigned(pull_request)
      puts "Unassigned PR #{pull_request['title']}"
      @state.process_pr(pull_request)
    end

    def process_pull_request_synchronize(pull_request)
      puts "Synchronize PR #{pull_request['title']}"
      @state.process_pr(pull_request)
    end

    def process_status()
      puts "A status!"
      # do nothing for now
    end

    def process_commit_comment()
      puts "A commit comment!"
      # do nothing for now
    end

    def process_issue_comment(repo, issue, comment)
      puts "An issue comment for issue #{issue['title']}"
      if not issue.key?("pull_request")
        return
      end
      puts "Issue is a pull request"
      @state.process_pr_comment(repo, issue, comment)
    end

    def process_pull_request_review_comment()
      puts "A PR review comment!"
      # do nothing for now
    end
  end

  # start the server if ruby file executed directly (or through daemon)
  run! if app_file == $0 or "crhub_daemon" == $0
end
