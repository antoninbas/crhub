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

require 'sinatra'
require 'json'
require 'octokit'
require 'sqlite3'
require 'thread'
require 'set'

configure do
  set :bind, '0.0.0.0'
end

get '/' do
  "Hello World!"
end

$GlobalState = {}

ACCESS_TOKEN = ENV["GITHUB_PERSONAL_TOKEN"]
db_name = "test.db"

# This is temporary. Sinatra comes with its own CL options parser.
# So I am using an env variable.
if not ENV.include?("repos")
  puts "You need to define the 'repos' env variable"
  puts "Usage: repos=\"antoninbas/repo1 antoninbas/repo2\""
  exit(1)
end
env_repos = ENV["repos"]
env_repos = env_repos.split()
if env_repos.length == 0
  puts "'repos' environment variable empty"
  puts "Usage: repos=\"antoninbas/repo1 antoninbas/repo2\""
  exit(1)
end

env_users_bypass = []
if ENV.include?("users_bypass")
  env_users_bypass = ENV["users_bypass"].split()
end

$users_bypass = env_users_bypass.to_set

$repos = env_repos

$repos.each do |repo|
  RepoState = {}
  RepoState[:sema] = Mutex.new
  RepoState[:busy] = Set.new
  $GlobalState[repo] = RepoState
end


before do
  @client = Octokit::Client.new(:access_token => ACCESS_TOKEN)
  @db = SQLite3::Database.new db_name
end
@client = Octokit::Client.new(:access_token => ACCESS_TOKEN)
@db = SQLite3::Database.new db_name

# # List tables for drop
# drop_script = @db.execute <<-SQL
# select 'drop table ' || name || ';' from sqlite_master where type = 'table';
# SQL

# # Drop all tables
# drop_script.each do |drop_one|
#   drop_one = drop_one.join(" ")
#   @db.execute(drop_one)
# end

def sanitize_repo_name(repo)
  return repo.sub('/', '---').gsub("-", "_")
end

# Create tables
$repos.each do |repo|
  repo = sanitize_repo_name(repo)
  s = "create table if not exists #{repo} (
         number integer primary key,
         id int unique,
         title text,
         user_id int,
         user_login text,
         assignee_id int,
         assignee_login text,
         sha text unique,
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

def db_update_pr(repo, number, id, title, user_id, user_login,
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

def db_add_review(repo, number, user_id, score)
  repo = sanitize_repo_name(repo)
  query = "insert or replace into #{repo}__reviews_ (number, user_id, score)
           values (?, ?, ?)"
  @db.execute(query, [number, user_id, score])
end

def db_get_status(repo, number)
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

def db_get_branch(repo, number)
  repo = sanitize_repo_name(repo)
  query = "select target_branch from #{repo}
           where #{repo}.number = ?"
  rows = @db.execute(query, number)
  if rows.length == 0
    return nil
  end
  return rows[0][0]
end

def db_get_easy(repo, number, attr)
  repo = sanitize_repo_name(repo)
  query = "select #{attr} from #{repo}
           where #{repo}.number = ?"
  rows = @db.execute(query, number)
  if rows.length == 0
    return nil
  end
  return rows[0][0]
end

def db_get_sha(repo, number)
  repo = sanitize_repo_name(repo)
  query = "select sha from #{repo} where number = ?"
  rows = @db.execute(query, number)
  raise "Corrupted DB (no sha)" unless rows.length == 1
  return rows[0][0]
end

def db_get_pr_entry(repo, number)
  repo = sanitize_repo_name(repo)
  query = "select * from #{repo} where number = ?"
  rows = @db.execute(query, number)
  if rows.length == 0
    return nil
  end
  return rows[0]
end

def pr_entry_get_sha(entry)
  return entry[7]
end

def db_show_prs(repo)
  repo = sanitize_repo_name(repo)
  query = "select * from #{repo}"
  @db.execute(query) do |row|
    puts row
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
  target_branch = db_get_branch(repo, number)
  if target_branch != "master"
    return
  end
  options = {}
  options[:context] = "crhub"
  options[:description] = "checks code review status"
  @client.create_status(repo, sha, status, options)
end

def repo_name_from_pr(pr)
  return pr['base']['repo']['full_name']
end

def push_status(repo, number, sha)
  user_login = db_get_easy(repo, number, 'user_login')
  if $users_bypass.include?(user_login)
    set_pr_status(repo, number, sha, "success")
    return
  end
  score = db_get_status(repo, number)
  if score > 0
    set_pr_status(repo, number, sha, "success")
  else
    set_pr_status(repo, number, sha, "failure")
  end
end

def request_access(repo, pr_number)
  repo_state = $GlobalState[repo]
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
  repo_state = $GlobalState[repo]
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
  changed = db_update_pr(repo, *entry)
  push_status(repo, pr['number'], pr['head']['sha'])
  release_access(repo, pr['number'])
end

def process_pr_comment(repo, issue, comment)
  # necessary?
  request_access(repo, issue['number'])
  # sha = db_get_sha(repo, issue['number'])
  db_entry = db_get_pr_entry(repo, issue['number'])
  if not db_entry
    puts "No PR matching comment, ignoring"
    release_access(repo, issue['number'])
    return
  end
  sha = pr_entry_get_sha(db_entry)
  set_pr_status(repo, issue['number'], sha, "pending")
  score = get_score(comment['body'])
  if score
    db_add_review(repo, issue['number'], comment["user"]["id"], score)
  end
  push_status(repo, issue['number'], sha)
  release_access(repo, issue['number'])
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
    process_pr(pull_request)
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
    process_pr(pull_request)
  end

  def process_pull_request_unassigned(pull_request)
    puts "Unassigned PR #{pull_request['title']}"
    process_pr(pull_request)
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
    process_pr_comment(repo, issue, comment)
  end

  def process_pull_request_review_comment()
    puts "A PR review comment!"
    # do nothing for now
  end
end
