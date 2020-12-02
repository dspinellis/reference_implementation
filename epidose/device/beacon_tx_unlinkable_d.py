#!/usr/bin/env python3

""" Contact tracing beacon transmitter """

__copyright__ = """
    Copyright 2020 Diomidis Spinellis

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
"""
__license__ = "Apache 2.0"

import argparse
from epidose.common.daemon import Daemon
from epidose.common.interruptible_sleep import InterruptibleSleep
from dp3t.config import EPOCH_LENGTH
from datetime import datetime
from dp3t.protocols.unlinkable_db import ContactTracer
from epidose.device.beacon_format import BLE_PACKET
import signal
import secrets
from sys import exit


def set_transmit(interface, ephid, rssi):
    """Set the Bluetooth low energy beacon to transmit on the specified
    interface the given 16-byte ephid with the given received signal
    strength indication (rssi).
    The beacon uses the AltBeacon format.
    For now the beacon code starts with ED 05 01 01, followed by the ephid.
    See https://github.com/AltBeacon/spec
    """

    assert len(ephid) == 16
    assert rssi >= 0 and rssi < 255

    cmd = [
        "hcitool",
        "-i",
        interface,
        "cmd",
        "0x08",
        "0x0008",  # HCI_LE_Set_Advertising_Data command (7.8.7, p. 1062)
    ]

    # Add BLE command
    ble = BLE_PACKET.hex()
    for p in range(0, len(BLE_PACKET) * 2, 2):
        cmd.append(ble[p : p + 2])

    # Add ephid
    ephid = ephid.hex()
    for p in range(0, 32, 2):
        cmd.append(ephid[p : p + 2])

    cmd.append(format(rssi, "x"))  # Reference RSSI
    cmd.append("01")  # Manufacturer reserved
    daemon.run_command(cmd)


def generate_random_bdaddr():
    """Generate a 6-byte hexadecimal number that will act
    as the new Bluetooth Device (MAC) Address (bdaddr),
    then return it in a MAC address-like format.
    """

    # 5d30c4a19c1e
    bdaddr = secrets.token_hex(6)
    # (5, d, 3, 0, c, 4, a, 1, 9, c, 1, e)
    bdaddr = list(bdaddr)

    # The values below denote that the bdaddr is locally administered
    locally_administered_elements = ["2", "6", "a", "e"]

    bdaddr[1] = secrets.choice(locally_administered_elements)
    # (5, 2, 3, 0, c, 4, a, 1, 9, c, 1, e) -> 5230c4a19c1e
    bdaddr = "".join(bdaddr)
    # 52 0x30 0xc4 0xa1 0x9c 0x1e
    bdaddr = " 0x".join(bdaddr[i : i + 2] for i in range(0, len(bdaddr), 2))
    # 0x52 0x30 0xc4 0xa1 0x9c 0x1e
    return "0x" + bdaddr


def main():
    parser = argparse.ArgumentParser(description="Contact tracing beacon trasmitter")
    parser.add_argument(
        "-d", "--debug", help="Run in debug mode logging to stderr", action="store_true"
    )
    parser.add_argument(
        "-D",
        "--database",
        help="Specify the database location",
        default="/var/lib/epidose/client-database.db",
    )
    parser.add_argument(
        "-i",
        "--iface",
        help="Transmit on the specified interface, not [hci]0",
        type=int,
        default=0,
    )
    parser.add_argument(
        "-n",
        "--dry-run",
        help="Do not execute the required command(s)",
        action="store_true",
    )
    parser.add_argument(
        "-r",
        "--rssi",
        help="Specify the received signal strength indication",
        type=int,
        default=0xC0,
    )
    parser.add_argument("-t", "--test", help="Test script", action="store_true")
    parser.add_argument(
        "-v", "--verbose", help="Set verbose logging", action="store_true"
    )
    args = parser.parse_args()

    if args.test:
        args.debug = True
        args.dry_run = True
        args.database = ":memory:"

    # Setup logging
    global daemon
    daemon = Daemon("beacon_tx", args)
    global logger
    logger = daemon.get_logger()

    global dry_run
    dry_run = args.dry_run

    interface = f"hci{args.iface}"

    # Transmit and store beacon packets
    current_ephid = None
    transmitter = ContactTracer(None, args.database, receiver=False)
    sleeper = InterruptibleSleep([signal.SIGTERM, signal.SIGINT])
    while True:
        now = datetime.now()
        transmitter.check_advance_day(now)
        ephid = transmitter.get_ephid_for_time(now)
        if ephid != current_ephid:

            # Generate random bdaddr
            bdaddr = generate_random_bdaddr()
            bdaddr = bdaddr.split()

            # Change local device bdaddr
            daemon.run_command(
                [
                    "hcitool",
                    "-i",
                    interface,
                    "cmd",
                    "0x3f",
                    "0x001",
                    bdaddr[5],
                    bdaddr[4],
                    bdaddr[3],
                    bdaddr[2],
                    bdaddr[1],
                    bdaddr[0],
                ]
            )

            # Enable the bluetooth interface
            daemon.run_command(["hciconfig", interface, "up"])

            # Enable LE advertising
            daemon.run_command(
                ["hcitool", "-i", interface, "cmd", "0x08", "0x000a", "01"]
            )

            set_transmit(interface, ephid, args.rssi)
            current_ephid = ephid
            logger.debug(f"Change ephid to {ephid.hex()}")

        # Wait for the current epoch (e.g. 15 minutes) to pass
        # The API can't tell us TTL, so sample every minute
        sleeper.sleep(EPOCH_LENGTH / 60)
        if sleeper.signaled:
            # Stop advertising
            daemon.run_command(["hciconfig", interface, "noleadv"])
            exit(0)
        if args.test:
            break


if __name__ == "__main__":
    main()
