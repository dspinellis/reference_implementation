#!/bin/sh
#
# Utilities for shell scripts
#
# Copyright 2020 Diomidis Spinellis
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
#

# Sleep time between retries to get the filter over WiFi (in seconds)
# 15 minutes
export WIFI_RETRY_TIME=$((15 * 60))

# Location of the Cuckoo filter
FILTER=/var/lib/epidose/client-filter.bin

# Location of the update script
UPDATE=/var/lib/epidose/update.sh

# Location of the current update version
CURRENT_UPDATE=/var/lib/epidose/current_update

# File with the latest update for the Ansible
LATEST_UPDATE=/var/lib/epidose/latest_update

# Location of update_filter_d sleep process file
export SLEEP_UPDATE_FILTER_PID=/var/run/epidose_update_filter_sleep

# Maximum allowed filter age before an update (in seconds)
# 6 hours
MAX_FILTER_AGE=$((6 * 60 * 60))

# Directory of WiFi users
WIFI_USERS=/var/lock/epidose/wifi-users

# Obtain exclusive access to the above directory
WIFI_USERS_LOCK=/var/lock/epidose/wifi-users.lock

# Pick up Python scripts from the same directory
SCRIPT_DIR="$(dirname "$0")"

# Pick Python from the current directory
PYTHON=venv/bin/python

# Get wlan0 MAC address
MAC_ADDRESS=$(ifconfig wlan0 | egrep -o '([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}')

# Log with a timestamp
log()
{
  # Output is redirected to the log file if needed at the script's lop level
  date +'%F %T ' | tr -d \\n 1>&2
  echo "$@" 1>&2
}

# Report usage information and exit with an error
usage()
{
  cat <<EOF 1>&2
Usage: $0 [-d] [-i] [-v] server-url
-d	Debug mode
-i	Use Python installed for the epidose venv
-v	Verbose logging
EOF
  exit 1
}

# Turn WiFi on and wait for it to associate
# Internal function
_wifi_on()
{
  log "Turn on WiFi"

  log "Temporary stop beacon transmissions"
  supervisorctl stop epidose:beacon_tx

  # No WiFi operations when running in debug mode
  test "$DEBUG_FLAG" && return
  ip link set wlan0 up
  sleep 15
}

# Turn WiFi off
# TODO: Check if "iwconfig wlan0 txpower off" yields additional power savings
# Internal function
_wifi_off()
{
  log "Turn off WiFi"

  log "Resume beacon transmissions"
  supervisorctl start epidose:beacon_tx

  # No WiFi operations when running in debug mode
  test "$DEBUG_FLAG" && return
  ip link set wlan0 down
}

# On return WiFi will be on and stay on until the last app releases it
wifi_acquire()
{
  log "Acquiring WiFi"
  (
    # Acquire exclusive access to the WiFi users directory
    flock -n 9 || exit 1
    if mkdir "$WIFI_USERS" 2>/dev/null ; then
      # Directory was not there; having created it, turn WiFi on
      _wifi_on
    fi
    # Add ourselves to the WiFi users
    touch "$WIFI_USERS/$APP_NAME"
  ) 9>"$WIFI_USERS_LOCK"
  log "Acquired WiFi"
}

# Release use of the WiFi.  When the last app releases it it will turn
# off
wifi_release()
{
  log "Releasing WiFi"
  (
    # Acquire exclusive access to the WiFi users directory
    flock -n 9 || exit 1
    # Remove ourselves from the WiFi users
    rm "$WIFI_USERS/$APP_NAME"
    # Try to remove the directory; will succeed only if we were the last user
    if rmdir "$WIFI_USERS" 2>/dev/null ; then
      # Directory removed; turn WiFi off
      _wifi_off
    fi
  ) 9>"$WIFI_USERS_LOCK"
  log "Released WiFi"
}

# Run the specified Python script from the local or installation directory
run_python()
{
  prog="$1"
  shift
  # shellcheck disable=SC2086
  "$PYTHON" "$SCRIPT_DIR"/"$prog".py $DEBUG_FLAG $VERBOSE_FLAG "$@"
}

# Check the validity of the cuckoo filter
# preconditions: none
# Outputs, through the stdout,
# the time interval until a Cuckoo filter is valid (in seconds)
# If 0 is returned, the Cuckoo filter is stale.
get_filter_validity_age()
{
  if [ -r "$FILTER" ] ; then
    filter_mtime=$(stat -c '%Y' "$FILTER")
    time_now=$(date +%s)
    filter_age=$((time_now - filter_mtime))
    if [ $filter_age -lt $MAX_FILTER_AGE ] ; then
      log "Filter's age ($filter_age s) is current; no update required"
      validity_time=$((MAX_FILTER_AGE - filter_age))
      echo "$validity_time"
    else
      log "Filter's age ($filter_age s) makes it stale; update required"
      validity_time=0
      echo "$validity_time"
    fi
  else
    log "No filter available; download required"
    mkdir -p "$(dirname $FILTER)"
  fi
}

# Obtain a (new) version of the Cuckoo filter
# preconditions: WiFi should be turned on
# Returns an exit code that defines
# whether a request to the ha-sever, to fetch a new cuckoo filter,
# was successful.
# If 1 is returned, then cuckoo filter was not obtained.
get_new_filter()
{
  if err=$(curl --silent --show-error --fail --output "$FILTER.new" \
    "$SERVER_URL/filter?mac=$MAC_ADDRESS" 2>&1) ; then
    # Atomically replace existing filter with new one
    mv "$FILTER.new" "$FILTER"
    log "New filter obtained: $(stat -c %s "$FILTER") bytes"
    return 0
  else
    exit_code=$?
    log "Unable to get filter: $err"
    return "$exit_code"
  fi
}

# Check which is the last performed update
# on the current device and update to the latest if needed.
# precondition: the sh $UPDATE should write
# in the file /var/lib/epidose/latest_update
# which is the latest needed update tag.
# For instance, $ echo "update_10" > /var/lib/epidose/latest_update
# in order to update until the 10th update tag.
update_ansible()
{
  # Get latest available update number
  latest_update=$(awk -F"_" '{print $2}' "$LATEST_UPDATE")

  # Check if the current_update file exists,
  # if not, start from the first update tag
  if [ ! -f "$CURRENT_UPDATE" ]; then
    log "No current_update found, starting from update_1"
    starting_update=1
    echo update_1 >> "$CURRENT_UPDATE"
  else
    starting_update=$(awk -F"_" '{print $2}' "$CURRENT_UPDATE")
    log "Updating up to update_$latest_update"
  fi

  # If the starting and latest are equal exit
  if [ "$starting_update" = "$latest_update" ]; then
    return 0
  fi

  # If the starting is larger than 1, then increase
  # it by one to avoid executing an unnecessary update
  if [ "$starting_update" -gt 1 ]; then
    starting_update=$((starting_update+1))
  fi

  # Execute Ansible with all update tag until the latest update tag
  for i in $(seq "$starting_update" "$latest_update"); do
    ansible-playbook /home/pi/epidose/epidose/device/install_and_configure.yml --tags "update_$i"
  done

  # Update current_update file with the latest update
  sed -i '1s/.*/update_'"$latest_update"'/' "$CURRENT_UPDATE"

  # Delete latest_update file
  rm "$LATEST_UPDATE"

  return 0
}

# Check and update device if necessary
# preconditions: WiFi should be turned on
check_for_updates()
{
  log "Checking for updates"
  if err=$(curl --silent --show-error --fail --output "$UPDATE" \
    "$SERVER_URL/update?mac=$MAC_ADDRESS" 2>&1) ; then
    log "New update script obtained: $(stat -c %s "$FILTER") bytes"
    sh $UPDATE
    update_ansible
  else
    log "Unable to get update script: $err"
  fi
}

if [ -z "$APP_NAME" ] ; then
  echo "APP_NAME not set" 1>&2
  exit 2
fi

# Parse command line options
while getopts 'div' c
do
  case $c in
    d)
      # Debug: Pass flag to other programs
      export DEBUG_FLAG=-d
      ;;
    i)
      PYTHON=/opt/venvs/epidose/bin/python
      SCRIPT_DIR=/opt/venvs/epidose/lib/python3.7/site-packages/epidose/device
      ;;
    v)
      # Verbose logging; pass to other programs
      export VERBOSE_FLAG=-v
      ;;
    *)
      echo "Invalid option $c" 1>&2
      usage
      ;;
  esac
done

shift $((OPTIND-1))


log 'Starting up'

# Obtain server URL
if [ -n "$1" ] ; then
  export SERVER_URL="$1"
elif [ -z "$SERVER_URL" ] ; then
  usage
fi

# Create lock directory
mkdir -p "$(dirname "$WIFI_USERS_LOCK")"
