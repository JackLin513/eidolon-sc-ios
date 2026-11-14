"""Pairing a body with a head for one costume.

The rules are pure given a `path -> materials` mapping, so the tests feed one in
rather than reading bundles.
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from export_corpus import choose_pair


def mats(*names: str) -> set[str]:
    return set(names)


class ChoosePairTests(unittest.TestCase):
    def test_body_and_head_of_the_same_costume_win(self) -> None:
        body, head = choose_pair("001har", "ss010", {
            "body": mats("cb_ss010_001har_01_m", "cb_ss010_001har_skin_m"),
            "head": mats(
                "ch_ss010_001har_face_m", "ch_pr001_001har_eyel_m",
                "ch_pr001_001har_eyer_m",
            ),
        })
        self.assertEqual(body, "body")
        self.assertEqual(head, "head")

    def test_a_base_head_is_the_fallback(self) -> None:
        body, head = choose_pair("001har", "ss010", {
            "body": mats("cb_ss010_001har_01_m"),
            "base": mats("ch_pr001_001har_face_m", "ch_pr001_001har_hair_m"),
        })
        self.assertEqual(body, "body")
        self.assertEqual(head, "base")

    def test_a_head_with_another_costumes_accessory_loses(self) -> None:
        body, head = choose_pair("001har", "ss010", {
            "head+acc": mats(
                "ch_ss010_001har_face_m", "ch_ss010_001har_acc01_m", "ch_pr001_001har_eyel_m"
            ),
            "plain": mats("ch_ss010_001har_face_m", "ch_pr001_001har_eyel_m"),
        })
        self.assertEqual(head, "plain")

    def test_eye_materials_do_not_count_as_foreign(self) -> None:
        _, head = choose_pair("001har", "ss010", {
            "head": mats(
                "ch_ss010_001har_face_m", "ch_pr001_001har_eyel_m", "ch_pr001_001har_eyer_m"
            ),
        })
        self.assertEqual(head, "head")

    def test_missing_parts_are_reported(self) -> None:
        body, head = choose_pair("001har", "ss010", {
            "head": mats("ch_ss010_001har_face_m"),
        })
        self.assertIsNone(body)
        self.assertEqual(head, "head")
        body, head = choose_pair("001har", "ss010", {"body": mats("cb_ss010_001har_01_m")})
        self.assertEqual(body, "body")
        self.assertIsNone(head)


if __name__ == "__main__":
    unittest.main()
