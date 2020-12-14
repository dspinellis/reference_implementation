#!/bin/sh
#
# Check for available networks and connect to the closest one using the WPS PBS
#
# Copyright 2020 Stefanos Georgiou
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

set -e

export APP_NAME=wps_scanner_d

# Location of suspend watchdod led
SUSPEND_WATCHDOG_LED=/var/lock/epidose/suspend-watchdog-led

# Pick up utility functions relative to the script's source code
UTIL="$(dirname "$0")/util.sh"

# Source common functionality (logging, WiFi)
# shellcheck source=epidose/device/util.sh
. "$UTIL"

# Light up LED lights to indicate network status messages.
# precondition: none
# Returns an exit code of 0 if a network connection is established,
# while exit code 1 denotes a failed attempt to connect to a WPS network,
# exit code 2 shows that there are no available WPS networks in the area,
# and value 3 refers to an invalid LED color option.
wps_led_blink()
{
  run_python device_io --"$1"-on
  case "$1" in
	"green") log "Obtained network connection"; return 0;;
	"red") log "Failed to connect to a network"; return 1;;
	"orange") log "No WPS network found in the area"; return 2;;
	*) log "The given LED option is not available"return 3;;
  esac
  sleep 3
  run_python device_io --"$1"-off
}

# Connect to a known network if available,
# otherwise try to connect to the network with
# the stongest signal by using WPS.
# precondition: WiFi should be turned on.
# Returns exit codes based on the return codes
# of the wps_led_blink function
wps_connect()
{

  # Check if device is connected to any network
  if check_if_ip_obtained; then
    return 0;
  fi

  log "Initiating WPS connection"
 
  # Suspend watchdog's LED activities
  touch "$SUSPEND_WATCHDOG_LED"
  
  # Get WPS network with the strongest signal
  network_with_strongest_signal=$(wpa_cli -i wlan0 scan_results | grep WPS | sort -r -k3 | tail -1)
  if [ -z "$network_with_strongest_signal" ] ; then
    # If there is no available WPS network in the area, turn on the orange LED light	    
    wps_led_blink orange
    exit_code=$?

    # Release watchdog
    rm "$SUSPEND_WATCHDOG_LED"
    return "$exit_code"
  fi	  

  # Get bssid of the strongest network signal and connect to it 
  echo "$network_with_strongest_signal" | awk '{print $1}' | xargs wpa_cli -i wlan0 wps_pbc
     
  # Get network name
  network_name=$(echo "$network_with_strongest_signal" | awk '{print $NF}')
  log "Trying to connect to $network_name"
    
  # Obtain dynamic IP address
  dhclient wlan0

  get_ip_address=$(ifconfig wlan0 | grep "inet ")
    
  # Check whether the connection is established and light up the LED accordingly
  if [ -z "$get_ip_address" ] ; then
    # If failed to connect to a network, turn on the red LED light
    wps_led_blink red
    exit_code=$?
  else
    # If connected to a network, turn on the green LED light
    wps_led_blink green
    exit_code=$?
  fi    
  
  # Release watchdog LED suspension
  rm "$SUSPEND_WATCHDOG_LED"
    
  return "$exit_code"
}

# Check whether the device has obtained
# an IP address from the dhclient
# preconditions: WiFi should be turned on
# Returns 0 if the device has an IP address
# or 1 if not
check_if_ip_obtained()
{
  get_ip_address=$(ifconfig wlan0 | grep "inet ")

  # Check if device has an IP address
  if [ -z "$get_ip_address" ] ; then
    log "Failed to connected to network"
    return 1
  fi

  # If the device has received an IP address,
  # then return 0
  log "Successfully connected to network"
  return 0
}

# Try to establish network connection
# with the configurations stored in
# the wpa_supplicant.conf file
# precondition: WiFi should be turned on
# Returns 0 if the device has successfully
# connected to a network or 1 if not
connect_to_saved_network()
{
  # Check if network $1 is in range
  get_network_if_in_range=$(wpa_cli -i wlan0 scan_results | grep "$1")
  if [ -z "$get_network_if_in_range"  ]; then
    log "Network $1 not in range"
    return 1
  fi

  # Get $1 network's id, list_networks checks the /etc/wpa_supplicant/wpa_supplicant.conf file
  get_network_id=$(wpa_cli list_networks | grep "$1" | cut -f 1)
  if [ -z "$get_network_id" ]; then
    log "Network $1 configurations may be missing from wpa_supplicant.conf"
    return 1
  fi

  # Try to connect to network $1
  if ! wpa_cli -i wlan0 select_network "$get_network_id"; then	
    log "Could not connect to network $1"
    log "Maybe $1 configurations are not correctly defined in the wpa_supplicant.conf"
    log "or the $1 network the device trying to connect has different password"
    return 1
  fi

  # Get an IP address
  dhclient wlan0
  if ! check_if_ip_obtained; then
    return 1
  fi

  return 0
}

# Checks if the device can connect
# first to Eduroam, then to Epidose backup,
# and then to an WPS-supported network
# precondition: none
# Returns 1 if the device failed
# to connect to any of the networks
select_network()
{
  log "Trying to connect to eduroam"
  if connect_to_saved_network eduroam; then
    wps_led_blink green
    return 0
  fi

  log "Trying to connect to epidose"
  if connect_to_saved_network epidose; then
    wps_led_blink green
    return 0
  fi

  log "Trying to connect with WPS"
  if wps_connect; then
   return 0
  fi

  return 1
}

while : ; do
  # Wait for the Wifi button to be pressed
  run_python device_io --wifi-wait
  wifi_acquire

  # Check if device can connect to Eduroam or Epidose backup network
  if select_network; then
    # Stop the sleep process of update_filter_d to get a new filter
    log "Killing update_filter_d's sleep process" 
    kill -9 "$(cat "$SLEEP_UPDATE_FILTER_PID")"
    # Allow time for update_filter to also acquire the WiFi
    sleep 5
  else
    log "Failed to connect to any network"
  fi

  run_python check_interface_risk "$FILTER" || :
  wifi_release
done
