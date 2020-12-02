__copyright__ = """
    Copyright 2020 Stefanos Georgiou

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

import types
from epidose.common.daemon import Daemon


def test_run_command():
    args = types.SimpleNamespace()
    args.debug = True
    args.verbose = True

    daemon = Daemon("test_run_command", args)
    global logger
    logger = daemon.get_logger()

    result = daemon.run_command(["true"])
    assert result.returncode == 0

    try:
        result = daemon.run_command(["false"])
    except Exception as e:
        logger.debug(f"{e}")
