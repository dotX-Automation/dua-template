#!/usr/bin/env bash

# Setup script for DUA repositories and projects.
#
# Roberto Masocco <robmasocco@gmail.com>
# Intelligent Systems Lab <isl.torvergata@gmail.com>
#
# April 5, 2023

# shellcheck disable=SC1003

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then set -o xtrace; fi

function usage {
  echo >&2 "Usage:"
  echo >&2 "    dua_setup.sh create [-a UNIT1,UNIT2,...] NAME TARGET PASSWORD"
  echo >&2 "    dua_setup.sh modify [-a UNIT1,UNIT2,...] [-r UNIT1,UNIT2,...] TARGET"
  echo >&2 "    dua_setup.sh delete TARGET"
  echo >&2 "See the README for more info."
}

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
  usage
  exit 1
fi

# Function to check that this script is executed in the root directory of the current repo.
function check_root {
  if [[ ! -d "bin" ]]; then
    echo >&2 "ERROR: This script must be executed in the root directory of the current repo"
    return 1
  else
    return 0
  fi
}

# Check that mkpasswd is available
if ! command -v mkpasswd &>/dev/null; then
  echo >&2 "ERROR: mkpasswd not found"
  exit 1
fi

# Function to convert a comma-separated list of modules to an array and return it.
function modules_to_array {
  local MODULES IFS
  IFS=',' read -r -a MODULES <<<"${1-}"

  # Check array length
  if [[ "${#MODULES[@]}" == "0" ]]; then
    echo >&2 "ERROR: No modules specified"
    return 1
  fi

  echo "${MODULES[@]}"
}

# Function to check that a target is valid.
function check_target {
  if [[ "${1-}" =~ ^(x86-base|x86-dev|x86-cudev|armv8-base|armv8-dev|jetson5c7)$ ]]; then
    return 0
  else
    echo >&2 "ERROR: Invalid target: ${1-}"
    return 1
  fi
}

# Function to add modules to a target.
function add_modules {
  # Parse the arguments
  local TARGET
  TARGET="${1-}"

  # If the module is one, just append it to the Dockerfile
  if [[ "${#ADD_MODULES[@]}" == "1" ]]; then
    MODULE="${ADD_MODULES[0]}"
    echo "Adding module ${MODULE} ..."
    sed -n "/### ${MODULE} START ###/,/### ${MODULE} END ###/p" "src/${MODULE}/docker/container-${TARGET}/Dockerfile" | \
      sed -e "1i### ${MODULE} START ###" -e "\$a### ${MODULE} END ###" | \
      sed -e '/### IMAGE SETUP END ###/i\' -e 'r /dev/stdin' "docker/container-${TARGET}/Dockerfile"
    return 0
  fi

  # Add the specified modules
  PREV_MODULE=""
  for MODULE in "${ADD_MODULES[@]}"; do
    # Check if the module is already present in the Dockerfile
    if grep -q "### ${MODULE} START ###" "docker/container-${TARGET}/Dockerfile"; then
      echo "Module ${MODULE} already present"
      PREV_MODULE="${MODULE}"
      continue
    fi

    if [[ -z "${PREV_MODULE}" ]]; then
      # Add the module at the beginning of the Dockerfile
      echo "Adding module ${MODULE} ..."
      sed -n "/### ${MODULE} START ###/,/### ${MODULE} END ###/p" "src/${MODULE}/docker/container-${TARGET}/Dockerfile" | \
        sed -e "1i### ${MODULE} START ###" -e "\$a### ${MODULE} END ###" | \
        sed -e '/### IMAGE SETUP END ###/ {r /dev/stdin' -e 'd}'
    else
      true
    fi
  done
}

# Function to remove modules from a target.
function remove_modules {
  # Parse the arguments
  local TARGET
  TARGET="${1-}"

  # Remove the specified modules
  for MODULE in "${REMOVE_MODULES[@]}"; do
    echo "Removing module ${MODULE} ..."
    sed -i "/### ${MODULE} START ###/,/### ${MODULE} END ###/d" "docker/container-${TARGET}/Dockerfile"
  done
}

# Function to create a new target.
function create_target {
  # Parse and check arguments
  local NAME TARGET PASSWORD HPSW
  NAME="${1-}"
  TARGET="${2-}"
  PASSWORD="${3-}"
  if ! check_target "${TARGET}"; then
    exit 1
  fi
  if [[ -z "${NAME}" || -z "${HPSW}" ]]; then
    echo >&2 "ERROR: Missing arguments"
    usage
    exit 1
  fi
  if [[ -d "docker/container-${TARGET}" ]]; then
    echo >&2 "ERROR: Target ${TARGET} already exists"
    exit 1
  fi
  HPSW=$(mkpasswd -m sha-512 intelsyslab "${PASSWORD}")
  SERVICE="${NAME}-${TARGET}"
  echo "Project name: ${NAME}"
  echo "Servcice name: ${SERVICE}"
  echo "Creating target ${TARGET} (password hash: ${HPSW}) ..."

  # Create the folder corresponding to the requested target
  mkdir "docker/container-${TARGET}"

  # Copy standard files
  cp "bin/dua-templates/context/aliases.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/bashrc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/colcon-defaults.yaml.template" "docker/container-${TARGET}/colcon-defaulst.yaml"
  cp "bin/dua-templates/context/commands.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/nanorc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/p10k.zsh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/ros2.sh" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/vimrc" "docker/container-${TARGET}/"
  cp "bin/dua-templates/context/zshrc" "docker/container-${TARGET}/"

  # Create and configure the Zsh history directory
  mkdir "docker/container-${TARGET}/zsh_history"
  cp "bin/dua-templates/context/gitignore-zsh_history" "docker/container-${TARGET}/zsh_history/.gitignore"

  # Copy and configure devcontainer.json
  cp "bin/dua-templates/devcontainer.json.template" "docker/container-${TARGET}/.devcontainer.json"
  sed -i "s/SERVICE/${SERVICE}/g" "docker/container-${TARGET}/.devcontainer.json"

  # Copy and configure docker-compose.yml
  if [[ "${TARGET}" == "x86-cudev" ]]; then
    cp "bin/dua-templates/docker-compose.yml.nvidia.template" "docker/container-${TARGET}/docker-compose.yml"
  else
    cp "bin/dua-templates/docker-compose.yml.template" "docker/container-${TARGET}/docker-compose.yml"
  fi
  sed -i "s/SERVICE/${SERVICE}/g" "docker/container-${TARGET}/docker-compose.yml"

  # Copy and configure Dockerfile
  cp "bin/dua-templates/Dockerfile.template" "docker/container-${TARGET}/Dockerfile"
  sed -i "s/TARGET/${TARGET}/g" "docker/container-${TARGET}/Dockerfile"
  sed -i "s/HPSW/${HPSW}/g" "docker/container-${TARGET}/Dockerfile"
  if [[ -n "${ADD-}" ]]; then
    add_modules "${TARGET}"
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

  # Add modules, if requested
  if [[ -n "${ADD-}" ]]; then
    add_modules "${TARGET}"
  fi

  # Remove modules, if requested
  if [[ -n "${REMOVE-}" ]]; then
    remove_modules "${TARGET}"
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
  echo "Removing target ${TARGET} ..."

  # Remove the folder corresponding to the requested target
  rm -rf "docker/container-${TARGET}"
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
    ADD_MODULES=$(modules_to_array "${OPTARG}")
    if [[ -z "${ADD_MODULES}" ]]; then
      exit 1
    fi
    ;;
  r)
    REMOVE=1
    REMOVE_MODULES=$(modules_to_array "${OPTARG}")
    if [[ -z "${REMOVE_MODULES}" ]]; then
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

# Check: create accepts only ADD
if [[ -n "${CREATE-}" ]]; then
  if [[ -n "${ADD-}" && -z "${REMOVE-}" ]]; then
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

# Execute the command
if [[ -n "${CREATE-}" ]]; then
  create_target "${@}"
elif [[ -n "${MODIFY-}" ]]; then
  modify_target "${@}"
elif [[ -n "${DELETE-}" ]]; then
  delete_target "${@}"
fi
