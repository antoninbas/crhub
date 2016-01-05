# -*- coding: utf-8 -*-
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

require 'daemons'

options = {
  :app_name => "crhub_daemon",
  # Write a backtrace of the last exceptions to the file
  # ‘[app_name].log’ in the pid-file directory if the application
  # exits due to an uncaught exception
  :backtrace => true,
  :log_output => true
}

script = File.join(File.dirname(File.expand_path(__FILE__)), 'crhub.rb')

Daemons.run(script, options = options)
