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
 * parseconfig
 * daemons (only to run in daemon mode, i.e. when using crhub_daemon.rb)

You also need to obtain a GitHub [personal token]
(https://github.com/settings/tokens) with the correct scope
(`repo:status` is the only required scope). Copy this token and add it
as environment variable `GITHUB_PERSONAL_TOKEN` to your server.

---

# Running crhub

Clone the crhub repo on your server and run it like this:

    ruby crhub.rb <path to crhub conf file>

For example:

    ruby crhub.rb crhub.conf

Take a look at the comments in the sample file [crhub.conf]
(crhub.conf) for more information.

The final step is to add crhub as a webhook for your repository. Use the
following configuration:

 * payload url: `http://<server_IP_addr>:4567/codereview`
 * events: `Pull Request` and `Issue Comment`

---

# Running as a daemon (on Unix)

To run crhub as a daemon, simply use the `crhub_daemon.rb` script
instead. The following commands are useful:

    ruby crhub_daemon.rb start -- <full path to crhub conf file>
    ruby crhub_daemon.rb stop
    ruby crhub_daemon.rb restart -- <full path to crhub conf file>
    ruby crhub_daemon.rb status

The crhub output will be logged to `crhub_daemon.output` (in the
script's directory).
