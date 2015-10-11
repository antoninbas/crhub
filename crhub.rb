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
env_repos = ENV["repos"]
if not ENV.include?("repos")
  puts "You need to define the 'repos' env variable"
  puts "Usage: repos=\"antoninbas/repo1 antoninbas/repo2\""
  exit(1)
end
env_repos = env_repos.split()
if env_repos.length == 0
  puts "'repos' environment variable empty"
  puts "Usage: repos=\"antoninbas/repo1 antoninbas/repo2\""
  exit(1)
end

$repos = env_repos

$repos.each do |repo|
  RepoState = {}
  RepoState[:sema] = Mutex.new
  RepoState[:skip] = Set.new
  RepoState[:busy] = Set.new
  $GlobalState[repo] = RepoState
end


before do
  @client = Octokit::Client.new(:access_token => ACCESS_TOKEN)
  @db = SQLite3::Database.new db_name
end
@client = Octokit::Client.new(:access_token => ACCESS_TOKEN)
@db = SQLite3::Database.new db_name

# List tables for drop
drop_script = @db.execute <<-SQL
select 'drop table ' || name || ';' from sqlite_master where type = 'table';
SQL

# Drop all tables
drop_script.each do |drop_one|
  drop_one = drop_one.join(" ")
  @db.execute(drop_one)
end

def sanitize_repo_name(repo)
  return repo.sub('/', '---').gsub("-", "_")
end

# Create tables (one per repo)
$repos.each do |repo|
  repo = sanitize_repo_name(repo)
  s = "create table #{repo} (
         id integer primary key,
         number int,
         title text,
         user_id int,
         user_login text,
         assignee_id int,
         assignee_login text,
         score int
       )"
  rows = @db.execute(s)
end

def db_update_pr(repo, id, number, title, user_id, user_login,
                 assignee_id, assignee_login, score)
  repo = sanitize_repo_name(repo)
  query = "select * from #{repo} where id = ?"
  rows = @db.execute(query, id)
  if rows.length == 0
    query = "insert into #{repo} (id, number, title, user_id, user_login, assignee_id, assignee_login, score)
             values (?, ?, ?, ?, ?, ?, ?, ?)"
    @db.execute(query, [id, number, title, user_id, user_login, assignee_id, assignee_login, score])
    return true
  end
  raise "Corrupted DB" unless rows.length == 1
  row = rows[0]
  raise "Corrupted DB" unless row[1] == number
  raise "Corrupted DB" unless row[2] == title
  raise "Corrupted DB" unless row[3] == user_id
  raise "Corrupted DB" unless row[4] == user_login
  if row[5] != assignee_id or row[7] != score
    query = "replace into #{repo} (id, number, title, user_id, user_login, assignee_id, assignee_login, score)
             values (?, ?, ?, ?, ?, ?, ?, ?)"
    @db.execute(query, [id, number, title, user_id, user_login, assignee_id, assignee_login, score])
    return true
  end
  return false
end

def db_show_prs(repo)
  repo = sanitize_repo_name(repo)
  query = "select * from #{repo}"
  @db.execute(query) do |row|
    puts row
  end
end

def get_score(repo, issue_number, assignee_id) # issue number is PR number
  comments = @client.issue_comments(repo, issue_number)
  score = 0
  comments.each do |c|
    if assignee_id != c['user']['id']
      next
    end
    case c['body']
    when "+1"
      score = 1
    when "-1"
      score = -1
    end
  end
  return score
end

def set_pr_status(pr, status)
  options = {}
  options[:context] = "crhub"
  options[:description] = "checks code review status"
  @client.create_status(pr['base']['repo']['full_name'], pr['head']['sha'], status, options)
end

def process_pr(pr, force_status)
  repo = pr['base']['repo']['full_name']
  entry = [pr['id'], pr['number'], pr['title'],
           pr['user']['id'], pr['user']['login']]
  score = 0
  if pr['assignee']
    entry += [pr['assignee']['id'], pr['assignee']['login']]
    score = get_score(repo, pr['number'], pr['assignee']['id'])
  else
    # no assignee yet
    entry += [nil, nil]
  end
  entry += [score]
  # puts entry.join(", ")
  changed = db_update_pr(repo, *entry)
  if force_status
    changed = true
  end
  if changed and score > 0
    set_pr_status(pr, "success")
  elsif changed
    set_pr_status(pr, "failure")
  end
end

def request_access(repo, pr_id)
  repo_state = $GlobalState[repo]
  repo_state[:sema].lock()
  while repo_state[:busy].include?(pr_id)
    repo_state[:sema].unlock()
    sleep(0)
    repo_state[:sema].lock()
  end
  repo_state[:busy].add(pr_id)
  repo_state[:sema].unlock()
end

def release_access(repo, pr_id)
  repo_state = $GlobalState[repo]
  repo_state[:sema].synchronize {
    repo_state[:busy].delete(pr_id)
  }
end

def process_pr_webhook(pr)
  repo = pr['base']['repo']['full_name']
  request_access(repo, pr['id'])
  repo_state = $GlobalState[repo]
  repo_state[:sema].synchronize {
    repo_state[:skip].add(pr['id'])
  }
  set_pr_status(pr, "pending")
  process_pr(pr, true)
  release_access(repo, pr['id'])
end

def process_issue_comment_webhook(repo, issue, comment)
  pr = @client.pull_request(repo, issue['number'])
  # I do not leverage the comment at all to make things simpler
  request_access(repo, pr['id'])
  repo_state = $GlobalState[repo]
  repo_state[:sema].synchronize {
    repo_state[:skip].add(pr['id'])
  }
  set_pr_status(pr, "pending")
  process_pr(pr, true)
  release_access(repo, pr['id'])
end

def update_all_prs()
  $repos.each do |repo|
    puts "Pulling PRs in #{repo}"
    repo_state = $GlobalState[repo]
    repo_state[:sema].synchronize {
      repo_state[:skip].clear()
    }
    opened_PRs = @client.pull_requests(repo, :state => 'opened')
    opened_PRs.each do |pr|
      request_access(repo, pr['id'])
      repo_state[:sema].synchronize {
        if repo_state[:skip].include?(pr['id'])
          next
        end
        process_pr(pr, false)
      }
      release_access(repo, pr['id'])
    end
  end
end

thr = Thread.new do
  loop do
    puts "Periodical PR update"
    update_all_prs()
    sleep(60)
  end
end

post '/codereview' do
  @payload = JSON.parse(request.body.read)

  case request.env['HTTP_X_GITHUB_EVENT']
  when "pull_request"
    action = @payload["action"] 
    case action
    when "opened"
      process_pull_request_opened(@payload["pull_request"])
    when "labeled"
      process_pull_request_labeled(@payload["pull_request"])
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
    process_pr_webhook(pull_request)
  end

  def process_pull_request_labeled(pull_request)
    puts "Labeled PR #{pull_request['title']}"
    # do nothing for now
  end

  def process_pull_request_assigned(pull_request)
    puts "Assigned PR #{pull_request['title']}"
    process_pr_webhook(pull_request)
  end

  def process_pull_request_unassigned(pull_request)
    puts "Unassigned PR #{pull_request['title']}"
    process_pr_webhook(pull_request)
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
    process_issue_comment_webhook(repo, issue, comment)
  end

  def process_pull_request_review_comment()
    puts "A PR review comment!"
    # do nothing for now
  end
end
