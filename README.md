crhub (CodeReview for GitHub)
============================

---

# Introduction

This repository contains code which implements a CI (Continuous Integration)
service for GitHub. This service is implemented in Ruby. It monitors pull
requests and attributes statuses to them. To receive the status *success*, a
pull request needs to fulfill the following conditions:

 * the pull request has an *assignee*
 * the *assignee* needs to leave a comment with body "+1"

---

# Pre-requisites

The following Ruby gems -along with their own dependencies- are required to run
crhub:

 * sinatra
 * json
 * octokit
 * sqlite3

You also need to obtain a GitHub [personal token]
(https://github.com/settings/tokens) with the correct scope
(`repo:status` is the only required scope). Copy this token and add it
as environment variable `GITHUB_PERSONAL_TOKEN` to your server.

---

# Running crhub

Clone the crhub repo on your server and run it like this:

    repos="<repo1> <repo2> ..." ruby crhub.rb

For example, to use crhub on the crhub repository:

    repos="antoninbas/crhub" ruby crhub.rb

The final step is to add crhub as a webhook for your repository. Use the
following configuration:

 * payload url: `http://<server_IP_addr>:4567/codereview`
 * events: `Pull Request` and `Issue Comment`

---
