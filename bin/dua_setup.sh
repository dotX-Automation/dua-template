#!/usr/bin/env bash

# Setup script for DUA repositories and projects.
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

# shellcheck disable=SC2207,SC2016

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then set -o xtrace; fi

function usage {
  echo >&2 "Usage:"
  echo >&2 "    dua_setup.sh create [-a UNIT1,UNIT2,...] NAME TARGET"
  echo >&2 "    dua_setup.sh modify [-a UNIT1,UNIT2,...] [-r UNIT1,UNIT2,...] TARGET"
  echo >&2 "    dua_setup.sh clear TARGET"
  echo >&2 "    dua_setup.sh delete TARGET"
  echo >&2 "See dua-template.md for more info."
}

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
  usage
  exit 1
fi

# Global, program state variables
declare -i CREATE
declare -i MODIFY
declare -i DELETE
declare -i CLEAR
declare -i ADD
declare -i REMOVE
declare -i NO_MKPASSWD
declare -i NO_GNU
declare -i MACOS
declare -a ADD_UNITS
declare -a REMOVE_UNITS

# Function to check that this script is executed in the root directory of the current repo.
function check_root {
  if [[ ! -d "docker" ]]; then
    echo >&2 "ERROR: This script must be executed in the root directory of the current repo"
    return 1
  else
    return 0
  fi
}

# Check if we're running on a supported OS
OS_NAME="$(uname -s)"
if [[ "$OS_NAME" == "Linux" ]]; then
  NO_GNU=0
elif [[ "$OS_NAME" == "Darwin" ]]; then
  NO_GNU=1
  MACOS=1
else
  echo >&2 "ERROR: Operating system not supported"
  exit 1
fi

# Check that mkpasswd is available
if ! command -v mkpasswd &>/dev/null; then
  NO_MKPASSWD=1
  echo "WARNING: mkpasswd is not available (try whois package?), using Python 3 passlib module instead"

  # Check that python3 with the passlib module is available
  if ! command -v python3 &>/dev/null; then
    echo >&2 "ERROR: mkpasswd is not available and Python 3 is not installed"
    exit 1
  elif ! python3 -c "import passlib" &>/dev/null; then
    echo >&2 "ERROR: mkpasswd is not available and Python 3 passlib module is not installed"
    exit 1
  fi
fi

# If running on Mac OS, check that gnu-sed is available and configure it as our sed
if [[ "$NO_GNU" == "1" ]]; then
  if ! command -v gsed &>/dev/null; then
    echo >&2 "ERROR: gnu-sed is not available"
    exit 1
  else
    SED="gsed"
  fi
else
  SED="sed"
fi

# Function to convert a comma-separated list of units to an array and return it.
function units_to_array {
  local UNITS IFS
  IFS=',' read -r -a UNITS <<<"${1-}"

  # Check array length
  if [[ "${#UNITS[@]}" == "0" ]]; then
    echo >&2 "ERROR: No units specified"
    return 1
  fi

  echo "${UNITS[@]}"
}

# Function to check that a target is valid.
function check_target {
  if [[ "${1-}" =~ ^(x86-base|x86-dev|x86-cudev|armv8-base|armv8-dev|jetson6|jetson5|jetsonnano|jetsontx2)$ ]]; then
    return 0
  else
    echo >&2 "ERROR: Invalid target: ${1-}"
    return 1
  fi
}

# Function to add units to a target.
function add_units {
  # Parse the arguments
  local TARGET
  TARGET="${1-}"

  # Create a temporary file descriptor for our needs
  exec 3>"$(mktemp)"
  local tmpfile="/dev/fd/3"

  # Create an associative array to track which units we've already added
  # This prevents duplicate additions in a single operation
  declare -A added_units

  # Always start by copying everything up to and including IMAGE SETUP START
  $SED -n '1,/^# IMAGE SETUP START #$/p' "docker/container-${TARGET}/Dockerfile" >&3

  if [[ "${#ADD_UNITS[@]}" -gt "1" ]]; then
    # For multiple units, start fresh after IMAGE SETUP START
    for UNIT in "${ADD_UNITS[@]}"; do
      # Skip if we've already added this unit in this operation
      if [[ ${added_units[$UNIT]+_} ]]; then
        continue
      fi

      # Mark this unit as added
      added_units[$UNIT]=1

      if grep -q "# ${UNIT} START #" "docker/container-${TARGET}/Dockerfile"; then
        # Copy existing unit configuration to preserve local changes
        echo "Copying unit ${UNIT} ..."
        $SED -n "/^# ${UNIT} START #$/,/^# ${UNIT} END #$/p" \
          "docker/container-${TARGET}/Dockerfile" >&3
      else
        # Add new unit from its source
        echo "Adding unit ${UNIT} ..."
        $SED -n "/^# ${UNIT} START #$/,/^# ${UNIT} END #$/p" \
          "src/${UNIT}/docker/container-${TARGET}/Dockerfile" >&3
      fi
    done
  else
    # For a single unit addition, only the version contained in the unit source is considered
    UNIT="${ADD_UNITS[0]}"

    # First, copy any existing units between IMAGE SETUP START and END
    # but exclude the unit we're about to add to avoid duplication
    $SED -n "/^# IMAGE SETUP START #$/,/^# IMAGE SETUP END #$/{
      /^# IMAGE SETUP/!{
        /^# ${UNIT} START #$/,/^# ${UNIT} END #$/!p
      }
    }" "docker/container-${TARGET}/Dockerfile" >&3

    # Then add the new/updated unit
    echo "Adding unit ${UNIT} ..."
    $SED -n "/^# ${UNIT} START #$/,/^# ${UNIT} END #$/p" \
      "src/${UNIT}/docker/container-${TARGET}/Dockerfile" >&3
  fi

  # Always end by adding IMAGE SETUP END and everything after it
  $SED -n '/^# IMAGE SETUP END #$/,$p' "docker/container-${TARGET}/Dockerfile" >&3

  # Replace the original file with our constructed version
  cat "$tmpfile" > "docker/container-${TARGET}/Dockerfile"

  # Clean up our file descriptor
  exec 3>&-
}

# Function to remove units from a target.
function remove_units {
  # Parse the arguments
  local TARGET
  TARGET="${1-}"

  # Remove the specified units
  for UNIT in "${REMOVE_UNITS[@]}"; do
    echo "Removing unit ${UNIT} ..."
    $SED -i "/^# ${UNIT} START #$/,/^# ${UNIT} END #$/d" "docker/container-${TARGET}/Dockerfile"
  done
}

# Function to clear all units from a target.
function clear_units {
  # Parse the arguments
  local TARGET VERBOSE
  TARGET="${1-}"
  VERBOSE="${2-1}"

  # Create a temporary file descriptor for our needs
  exec 3>"$(mktemp)"
  local tmpfile="/dev/fd/3"

  if [[ "${VERBOSE}" == "1" ]]; then
    echo "Removing all units from target ${TARGET} ..."
  fi

  # Copy everything up to and including IMAGE SETUP START
  $SED -n '1,/^# IMAGE SETUP START #$/p' "docker/container-${TARGET}/Dockerfile" >&3

  # Copy IMAGE SETUP END and everything after it
  $SED -n '/^# IMAGE SETUP END #$/,$p' "docker/container-${TARGET}/Dockerfile" >&3

  # Replace the original file with our constructed version
  cat "$tmpfile" > "docker/container-${TARGET}/Dockerfile"

  # Clean up our file descriptor
  exec 3>&-
}

# Function to create a new target.
function create_target {
  # Parse and check arguments
  local NAME TARGET PASSWORD HPSW
  NAME="${1-}"
  TARGET="${2-}"
  if ! check_target "${TARGET}"; then
    exit 1
  fi
  if [[ -z "${NAME}" ]]; then
    echo >&2 "ERROR: Missing arguments"
    usage
    exit 1
  fi
  if [[ -d "docker/container-${TARGET}" ]]; then
    echo >&2 "ERROR: Target ${TARGET} already exists"
    exit 1
  fi

  # Ask for a password
  read -r -s -p "Enter password for internal user: " PASSWORD
  if [[ -z "${PASSWORD}" ]]; then
    echo >&2 "ERROR: Empty password"
    exit 1
  fi
  if [[ "${NO_MKPASSWD-0}" == "1" ]]; then
    # Use Python 3 with passlib
    HPSW=$(python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('${PASSWORD}', salt='duatemplate', rounds=5000))")
  else
    HPSW=$(mkpasswd -m sha-512 "${PASSWORD}" duatemplate)
  fi

  SERVICE="${NAME}-${TARGET}"
  echo "Project name: ${NAME}"
  echo "Service name: ${SERVICE}"
  echo "Creating target ${TARGET} (password hash: ${HPSW}) ..."

  # Create the folder corresponding to the requested target
  mkdir -p "docker/container-${TARGET}/.devcontainer"

  # Copy standard files
  cp "bin/dua-templates/context/aliases.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/bashrc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/colcon-defaults.yaml.template" "docker/container-${TARGET}/colcon-defaults.yaml"
  cp "bin/dua-templates/context/commands.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/dua_submod.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/dua_subtree.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/nanorc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/p10k.zsh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/ros2.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/vimrc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/zshrc" "docker/container-${TARGET}/"

  # Create and configure the Zsh history directory
  mkdir "docker/container-${TARGET}/zsh_history"
  cp "bin/dua-templates/context/gitignore-zsh_history" "docker/container-${TARGET}/zsh_history/.gitignore"

  # Copy and configure devcontainer.json
  cp "bin/dua-templates/devcontainer.json.template" "docker/container-${TARGET}/.devcontainer/devcontainer.json"
  $SED -i "s/SERVICE/${SERVICE}/g" "docker/container-${TARGET}/.devcontainer/devcontainer.json"

  # Copy and configure docker-compose.yml
  if [[ "${TARGET}" == "x86-cudev" ]] || [[ "${TARGET}" == "jetsonnano" ]] || [[ "${TARGET}" == "jetsontx2" ]]; then
    # Compose file for Nvidia devices (including 1st gen. legacy targets)
    cp "bin/dua-templates/docker-compose.yaml.nvidia.template" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  elif [[ "${TARGET}" == "armv8-dev" ]] && [[ "${MACOS-0}" == "1" ]]; then
    # Compose file for macOS ARM64
    cp "bin/dua-templates/docker-compose.yaml.macos.template" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  elif [[ "${TARGET}" == "jetson6" ]] || [[ "${TARGET}" == "jetson5" ]]; then
    # Compose file for Jetson devices with JetPack 5.x/6.x, need only runtime specified
    cp "bin/dua-templates/docker-compose.yaml.template" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
    $SED -i "s/ipc: host/&\n    runtime: nvidia/g" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  else
    # Compose file for anything else
    cp "bin/dua-templates/docker-compose.yaml.template" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  fi
  $SED -i "s/SERVICE/${SERVICE}/g" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  $SED -i "s/NAME/${NAME}/g" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  $SED -i "s/TARGET/${TARGET}/g" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"

  # Add restart policy for SBC targets
  if [[ "${TARGET}" == "x86-base" ]] || \
     [[ "${TARGET}" == "armv8-base" ]] || \
     [[ "${TARGET}" == "jetson6" ]] || \
     [[ "${TARGET}" == "jetson5" ]] || \
     [[ "${TARGET}" == "jetsontx2" ]] || \
     [[ "${TARGET}" == "jetsonnano" ]]; then
    $SED -i "s/network_mode: \"host\"/&\n    restart: always/g" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  fi

  # Add necessary groups for Jetson devices running JetPack 6.x to access GPU and onboard peripherals
  if [[ "${TARGET}" == "jetson6" ]]; then
    $SED -i "/user: neo/a\\    group_add:\\n      - 10\\n      - 20\\n      - 29\\n      - 30\\n      - 44\\n      - 46\\n      - 104\\n      - 116\\n      - 999" "docker/container-${TARGET}/.devcontainer/docker-compose.yaml"
  fi

  # Copy and configure Dockerfile, adding units if requested
  if [[ "${TARGET}" == "armv8-dev" ]] && [[ "${MACOS-0}" == "1" ]]; then
    cp "bin/dua-templates/Dockerfile.macos.template" "docker/container-${TARGET}/Dockerfile"
  else
    cp "bin/dua-templates/Dockerfile.template" "docker/container-${TARGET}/Dockerfile"
  fi
  $SED -i "s/TARGET/${TARGET}/g" "docker/container-${TARGET}/Dockerfile"
  $SED -i "s/HPSW/${HPSW//\//\\/}/g" "docker/container-${TARGET}/Dockerfile"
  if [[ -n "${ADD-}" ]]; then
    add_units "${TARGET}"
  fi
}

# Function to modify an existing target.
function modify_target {
  # Parse and check arguments
  local TARGET
  TARGET="${1-}"
  if ! check_target "${TARGET}"; then
    exit 1
  fi
  if [[ ! -d "docker/container-${TARGET}" ]]; then
    echo >&2 "ERROR: Target ${TARGET} does not exist"
    exit 1
  fi
  echo "Modifying target ${TARGET} ..."

  # Remove units, if requested
  if [[ -n "${REMOVE-}" ]]; then
    remove_units "${TARGET}"
  fi

  # Clear units, if requested
  if [[ -n "${CLEAR-}" ]]; then
    clear_units "${TARGET}"
  fi

  # Add units, if requested
  if [[ -n "${ADD-}" ]]; then
    add_units "${TARGET}"
  fi
}

# Function to delete an existing target.
function delete_target {
  # Parse and check argument
  local TARGET
  TARGET="${1-}"
  if ! check_target "${TARGET}"; then
    exit 1
  fi
  if [[ ! -d "docker/container-${TARGET}" ]]; then
    echo >&2 "ERROR: Target ${TARGET} does not exist"
    exit 1
  fi
  echo "Removing target ${TARGET} ..."

  # Remove the folder corresponding to the requested target
  rm -rf "docker/container-${TARGET}"
}

# Function to clear units from an existing target.
function clear_target {
  # Parse and check argument
  local TARGET
  TARGET="${1-}"
  if ! check_target "${TARGET}"; then
    exit 1
  fi
  if [[ ! -d "docker/container-${TARGET}" ]]; then
    echo >&2 "ERROR: Target ${TARGET} does not exist"
    exit 1
  fi
  echo "Clearing units from target ${TARGET} ..."

  # Remove all units
  clear_units "${TARGET}"
}

# Check that the path is correct
if ! check_root; then
  exit 1
fi

# Check that a command is specified
if [[ -z "${1-}" ]]; then
  echo >&2 "ERROR: No command specified"
  usage
  exit 1
fi

# Parse the command and shift it out of the arguments
case "${1-}" in
create)
  CREATE=1
  ;;
modify)
  MODIFY=1
  ;;
delete)
  DELETE=1
  ;;
clear)
  CLEAR=1
  ;;
*)
  echo >&2 "ERROR: Invalid command: ${1-}"
  usage
  exit 1
  ;;
esac
shift

# Parse options
while getopts ":a:r:" opt; do
  case ${opt} in
  a)
    ADD=1
    ADD_UNITS=($(units_to_array "${OPTARG}"))
    if [[ "${#ADD_UNITS[@]}" -eq "0" ]]; then
      exit 1
    fi
    ;;
  r)
    REMOVE=1
    REMOVE_UNITS=($(units_to_array "${OPTARG}"))
    if [[ "${#REMOVE_UNITS[@]}" -eq "0" ]]; then
      exit 1
    fi
    ;;
  \?)
    echo >&2 "ERROR: Invalid option: -${OPTARG}"
    usage
    exit 1
    ;;
  :)
    echo >&2 "ERROR: Option -${OPTARG} requires an argument"
    usage
    exit 1
    ;;
  esac
done
shift $((OPTIND -1))

# Check: create accepts only ADD
if [[ -n "${CREATE-}" && -n "${ADD-}" ]]; then
  if [[ -z "${REMOVE-}" ]]; then
    true
  else
    echo >&2 "ERROR: Invalid options for create"
    usage
    exit 1
  fi
fi

# Check: modify accepts one of ADD or REMOVE or both
if [[ -n "${MODIFY-}" ]]; then
  if [[ -n "${ADD-}" || -n "${REMOVE-}" ]]; then
    true
  else
    echo >&2 "ERROR: Invalid options for modify"
    usage
    exit 1
  fi
fi

# Check: clear accepts no options
if [[ -n "${CLEAR-}" ]]; then
  if [[ -z "${ADD-}" && -z "${REMOVE-}" ]]; then
    true
  else
    echo >&2 "ERROR: Invalid options for clear"
    usage
    exit 1
  fi
fi

# Execute the command
if [[ -n "${CREATE-}" ]]; then
  create_target "${@}"
elif [[ -n "${MODIFY-}" ]]; then
  modify_target "${@}"
elif [[ -n "${DELETE-}" ]]; then
  delete_target "${@}"
elif [[ -n "${CLEAR-}" ]]; then
  clear_target "${@}"
fi
echo "Remember to commit the changes ASAP!"
