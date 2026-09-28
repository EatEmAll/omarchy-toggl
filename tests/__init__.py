"""Test package. Safety net: the whole test run (and every subprocess it starts)
gets a stub `secret-tool` first on PATH, so no test can ever read, write or
clear the real user's keyring entry, even if it forgets tests.fakes.isolated_env()."""

import os
import tempfile

_stub_dir = tempfile.mkdtemp(prefix="omarchy-toggl-stub-bin-")
_stub = os.path.join(_stub_dir, "secret-tool")
with open(_stub, "w") as _f:
    _f.write("#!/bin/sh\nexit 1\n")
os.chmod(_stub, 0o755)
os.environ["PATH"] = _stub_dir + os.pathsep + os.environ.get("PATH", "")
