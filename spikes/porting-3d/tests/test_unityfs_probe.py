import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from unityfs_probe import read_unity_bundle_header, scan


def bundle_bytes(
    minimum_player_version: str,
    unity_version: str,
    format_version: int = 6,
) -> bytes:
    return (
        b"UnityFS\0"
        + struct.pack(">I", format_version)
        + minimum_player_version.encode() + b"\0"
        + unity_version.encode() + b"\0"
        + b"\0" * 32
    )


class UnityBundleHeaderTests(unittest.TestCase):
    def test_reads_the_unity_version_from_a_bundle_header(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bundle"
            path.write_bytes(bundle_bytes("5.x.x", "2021.3.36f1"))
            header = read_unity_bundle_header(path)
        self.assertIsNotNone(header)
        assert header is not None
        self.assertEqual(header.format_version, 6)
        self.assertEqual(header.minimum_player_version, "5.x.x")
        self.assertEqual(header.unity_version, "2021.3.36f1")

    def test_returns_none_for_a_non_bundle_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "not-a-bundle"
            path.write_bytes(b"PK\x03\x04 not UnityFS")
            self.assertIsNone(read_unity_bundle_header(path))

    def test_scan_groups_by_the_unity_revision_not_the_minimum_player_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bundle").write_bytes(bundle_bytes("5.x.x", "2021.3.36f1"))
            summary = scan(root)
        self.assertEqual(summary.versions, {"2021.3.36f1": 1})

    def test_scan_groups_bundles_by_unity_version_and_ignores_other_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a").mkdir()
            (root / "a" / "one").write_bytes(bundle_bytes("5.x.x", "2018.4.11f1"))
            (root / "a" / "two").write_bytes(bundle_bytes("5.x.x", "2021.3.36f1"))
            (root / "three").write_bytes(b"not a bundle")
            summary = scan(root)
        self.assertEqual(summary.bundle_count, 2)
        self.assertEqual(summary.versions, {"2018.4.11f1": 1, "2021.3.36f1": 1})
        self.assertGreater(summary.total_bytes, 0)


if __name__ == "__main__":
    unittest.main()
