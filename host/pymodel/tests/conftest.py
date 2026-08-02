"""Make ``host.pymodel`` importable when pytest is run from anywhere.

``host/`` has NO ``__init__.py`` — it is a PEP 420 namespace package, and it
must stay that way: another agent owns ``host/pyproject.toml`` and ``host/``
also holds C++ sources.  Putting the repository root on ``sys.path`` is all
that is needed for ``import host.pymodel`` to work.
"""

from __future__ import annotations

import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
