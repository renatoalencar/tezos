"""
Tests common utility functionality of binaries shipped with Tezos.
"""

import subprocess
from typing import List

from process import process_utils
from tools import paths
from . import protocol


PROTO_BINARIES = [
    binary + "-" + protocol.DAEMON
    for binary in ["octez-baker", "octez-accuser"]
]

BINARIES = [
    "octez-codec",
    "octez-client",
    "octez-admin-client",
    "octez-protocol-compiler",
    "octez-node",
    "octez-snoop",
    "octez-validator",
] + PROTO_BINARIES


def run_cmd(cmd: List[str]) -> str:
    """Pretty print a command. Execute it, print and return its standard
    output."""
    print(process_utils.format_command(cmd))
    process_ret = subprocess.run(
        cmd, check=True, capture_output=True, text=True
    )
    print(process_ret.stdout)
    return process_ret.stdout.strip()


class TestBinaries:
    def test_version(self):
        """Tests that all binaries accept the --version flag and that the
        report the same version"""
        versions = set()
        for binary in BINARIES:
            version = run_cmd([paths.TEZOS_HOME + binary, "--version"])
            versions.add(version)
        assert len(versions) == 1, "All binaries should report the same version"
