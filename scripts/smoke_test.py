#!/usr/bin/env python3
"""Background-only UI test. Never starts BLE, requests permissions or registers login."""
from pathlib import Path
import os
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
exe = project / "build/BookooHydrationStandalone.app/Contents/MacOS/BookooHydration"
# Use TMPDIR supplied by the host, not a fixed system temporary path.
with tempfile.TemporaryDirectory(prefix="bookoo-smoke-") as tmp:
    root = Path(tmp)
    for page in ("status", "settings", "records"):
        data = root / page
        data.mkdir()
        fixtures = {"hydration.json": b"{broken-hydration", "settings.json": b"{broken-settings", "reminder-state.json": b"{broken-state"}
        for name, content in fixtures.items():
            (data / name).write_bytes(content)
        image = project / "build" / f"smoke-{page}.png"
        env = dict(os.environ, BOOKOO_PREVIEW="1", BOOKOO_DATA_ROOT=str(data),
                   BOOKOO_UI_TEST_SHOW_WINDOW="1", BOOKOO_PREVIEW_ACTION_TEST="1", BOOKOO_UI_TEST_PAGE=page,
                   BOOKOO_UI_TEST_SNAPSHOT_PATH=str(image),
                   BOOKOO_UI_TEST_HEIGHT="1400" if page == "settings" else "650")
        result = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=30, check=True)
        assert image.is_file() and image.stat().st_size > 5000, f"Missing rendered snapshot: {page}"
        import struct
        width, height = struct.unpack(">II", image.read_bytes()[16:24])
        assert width >= 840 and height >= 650, "Snapshot below minimum layout bounds"
        assert not (data / "bluetooth-status.json").exists(), "BLE unexpectedly initialized"
        assert {p.name for p in data.iterdir()} == set(fixtures), "Preview created unexpected files/backups"
        for name, content in fixtures.items():
            assert (data / name).read_bytes() == content, f"Preview changed fixture: {name}"
        print(result.stdout.strip())
    print("PASS: 3 isolated UI snapshots; corrupt files preserved; UI actions blocked; no Bluetooth or permission requests")
