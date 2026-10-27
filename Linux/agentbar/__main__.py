"""Run with: python3 -m agentbar (from Linux/)."""
import argparse
import fcntl
import os
import signal
import ssl
import threading
from pathlib import Path

from .collector import Collector
from .accounts import AccountSelection
from .credentials import CredentialSource
from .history import HistoryStore
from .server import Server, access_key


def main():
    parser = argparse.ArgumentParser(description="AgentBar Linux Web — read local CLI credentials and collect quota history")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--interval", type=int, default=60, help="Polling interval in seconds (minimum 10)")
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "agentbar")
    parser.add_argument("--config", type=Path, default=Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "agentbar/config.json")
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    args = parser.parse_args()
    if args.interval < 10:
        parser.error("--interval must be at least 10 seconds")
    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error("--tls-cert and --tls-key must be supplied together")
    os.umask(0o077)
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (args.data_dir / "server.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("AgentBar is already running with this data directory")
    key_path = args.data_dir / "web-access-key"
    history = HistoryStore(args.data_dir / "quota-history.sqlite3")
    selection = AccountSelection(args.data_dir / "accounts.json")
    collector = Collector(CredentialSource(config=args.config), history, selection, args.interval)
    server = Server((args.host, args.port), collector, access_key(key_path))
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(args.tls_cert), str(args.tls_key))
        server.socket = context.wrap_socket(server.socket, server_side=True)

    def shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    collector.start()
    scheme = "https" if args.tls_cert else "http"
    print("AgentBar listening on %s://%s:%s" % (scheme, args.host, server.server_port), flush=True)
    print("Web access key file: %s" % key_path, flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        collector.stop()
        lock.close()


if __name__ == "__main__":
    main()
