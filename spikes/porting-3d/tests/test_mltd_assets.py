import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from mltd_assets import (
    ASSET_HOST,
    AssetEntry,
    MissingAsset,
    UnknownPlatform,
    asset_url,
    find_assets,
    parse_manifest,
)

MANIFEST = [
    {
        "cb_pr001_014mir.unity3d": [
            "90c01f73992bdc20bc3660d0bc6e4f27346f09e7",
            "82744590b1494ec51a42bf9417f39da3493fc419.unity3d",
            476517,
        ]
    },
    {
        "ch_pr001_014mir.unity3d": [
            "191fdc189882fb0e2f2874c39ff93dfe94c5dbab",
            "5cb515baa8f9472909d38995aaec3d49366ddeea.unity3d",
            464682,
        ]
    },
]


class ParseManifestTests(unittest.TestCase):
    def test_reads_every_entry_keyed_by_asset_name(self) -> None:
        assets = parse_manifest(MANIFEST)

        self.assertEqual(
            sorted(assets), ["cb_pr001_014mir.unity3d", "ch_pr001_014mir.unity3d"]
        )

    def test_keeps_the_hash_file_name_and_size(self) -> None:
        assets = parse_manifest(MANIFEST)

        self.assertEqual(
            assets["cb_pr001_014mir.unity3d"],
            AssetEntry(
                name="cb_pr001_014mir.unity3d",
                hash="90c01f73992bdc20bc3660d0bc6e4f27346f09e7",
                file="82744590b1494ec51a42bf9417f39da3493fc419.unity3d",
                size=476517,
            ),
        )


class AssetUrlTests(unittest.TestCase):
    def test_builds_the_ios_url_from_the_version_and_file_name(self) -> None:
        entry = parse_manifest(MANIFEST)["cb_pr001_014mir.unity3d"]

        self.assertEqual(
            asset_url(1078000, "ios", entry),
            f"{ASSET_HOST}/1078000/production/2018/iOS/"
            "82744590b1494ec51a42bf9417f39da3493fc419.unity3d",
        )

    def test_capitalises_the_platform_the_way_the_cdn_expects_it(self) -> None:
        entry = parse_manifest(MANIFEST)["cb_pr001_014mir.unity3d"]

        self.assertIn("/Android/", asset_url(1078000, "android", entry))

    def test_refuses_a_platform_that_is_not_part_of_the_url_layout(self) -> None:
        entry = parse_manifest(MANIFEST)["cb_pr001_014mir.unity3d"]

        with self.assertRaises(UnknownPlatform):
            asset_url(1078000, "windows", entry)


class FindAssetsTests(unittest.TestCase):
    def test_returns_the_entries_in_the_order_they_were_asked_for(self) -> None:
        assets = parse_manifest(MANIFEST)

        found = find_assets(assets, ["ch_pr001_014mir.unity3d", "cb_pr001_014mir.unity3d"])

        self.assertEqual(
            [entry.name for entry in found],
            ["ch_pr001_014mir.unity3d", "cb_pr001_014mir.unity3d"],
        )

    def test_names_every_missing_asset_at_once(self) -> None:
        assets = parse_manifest(MANIFEST)

        with self.assertRaises(MissingAsset) as raised:
            find_assets(assets, ["ch_pr001_014mir.unity3d", "dan_nope.unity3d"])

        self.assertIn("dan_nope.unity3d", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
