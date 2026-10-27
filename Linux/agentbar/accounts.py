"""AgentBar account membership only; CLI credential files remain read-only."""
import json
import os
import tempfile
import threading
from pathlib import Path


class AccountSelection:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.RLock()
        self.selected = json.loads(self.path.read_text()) if self.path.exists() else {}
        if not isinstance(self.selected, dict):
            raise ValueError("Invalid account selection file")

    def accounts(self):
        with self.lock:
            return {key: dict(value) for key, value in self.selected.items()}

    def set(self, key, account=None):
        with self.lock:
            updated = dict(self.selected)
            if account is None:
                updated.pop(key, None)
            else:
                updated[key] = {"provider": account.provider, "label": account.label}
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".accounts-", dir=str(self.path.parent))
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(updated, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, str(self.path))
                self.selected = updated
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
