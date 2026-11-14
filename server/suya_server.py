"""Startet den Suya-Server (Aufbau: Paket suya/, siehe suya/__init__.py).
Nur Python-Standardbibliothek plus cryptography/cbor2 für App Attest. Läuft hinter dem DSM-Reverse-Proxy."""
import os
import sys
import threading
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # mit python -I fehlt das eigene Verzeichnis

from suya import api, config, storage  # noqa: E402


def main():
    os.makedirs(os.path.join(config.DATA, "spender"), exist_ok=True)
    threading.Thread(target=storage.cleanup_loop, daemon=True).start()
    print("Suya-Server auf Port", config.PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", config.PORT), api.Handler).serve_forever()


if __name__ == "__main__":
    main()
