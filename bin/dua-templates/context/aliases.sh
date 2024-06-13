#!/usr/bin/env bash

# Custom aliases for container internal shell.
#
# Roberto Masocco <r.masocco@dotxautomation.com>
#
# June 13, 2024

# Copyright 2024 dotX Automation s.r.l.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Add custom, general-purpose aliases here.
# You can also source other files from sub-units included by this project.

alias ls='ls --color=auto'
alias ll='ls -la'
alias valgrind-check='valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes --verbose --log-file=valgrind.out'
