#!/bin/sh
#
# Script to generate private/public keys and sign Cuckoo filters
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

export APP_NAME=sign_filter

# Path towards the private key
PRIVATE_KEY="/var/lib/epidose/privateFilter.pem"

# Path towards the public key
PUBLIC_KEY="/var/lib/epidose/publicFilter.pem"

# Path of the signature
SIGNATURE_PATH="/var/lib/epidose/signature.sha256"

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
Usage: $0 [-s] fileToSign [-g]
-g, --generate		        Generate public/private key pair
-s, --sign "filterPath"		Sign theCuckoo filter
-h, --help			Usage instructions
EOF
exit 1
}

# Create the private/public keys
# preconditions: cracklib-check must be installed
createKeys()
{
  # Generate private and public keys
  openssl genpkey -algorithm RSA -out "$PRIVATE_KEY" -pkeyopt rsa_keygen_bits:4096
  openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY"
  log "Public and private keys created under the /var/lib/epidose directory"
  return 0
}

# Sign the given cuckoo filter
# preconditions: createKeys function should be called
# before this one
# Return 1 if failed to sign or 0 if succeeded
signFilter()
{
  # Create signature
  if ! openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$SIGNATURE_PATH" "$1"; then
    log "Failed to sign filter; please do not distribute"
    return 1
  fi

  log "Filter signed; ready to distribute"
  return 0
}

OPTIONS=$(getopt -o gs:h --long generate,sign,help -n 'cuckoo_filter_digital_signature' -- "$@")
eval set -- "$OPTIONS"
while true; do
  case "$1" in
    -g|--generate) createKeys; shift;;
    -s|--sign)
      case "$2" in
	"") >&2 log "Please provide the filter path"; exit 1;;
	*) signFilter "$2"; shift 2;;
      esac;;
    -h|--help) usage; shift;;
    --) shift; break;;
    *) >&2 log "Wrong command line argument, please try again or use --help for more info"; exit 1;;
  esac
done
