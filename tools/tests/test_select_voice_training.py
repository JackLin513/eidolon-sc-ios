from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import select_voice_training as selector  # noqa: E402


class TrainingSelectionTests(unittest.TestCase):
    def test_clean_removes_controller_tags(self) -> None:
        self.assertEqual(selector.clean("「你好<br>%0再见%10」"), "「你好、再见、」")

    def test_features_cover_primary_sentence_classes(self) -> None:
        self.assertEqual(selector.features("「真的吗？」", None)[:2], ("question", "short"))
        self.assertEqual(selector.features("「不要！」", None)[:2], ("exclaim", "short"))
        self.assertEqual(selector.features("「那个……」", None)[:2], ("hesitate", "short"))
        self.assertEqual(selector.features("「我知道了」", None)[:2], ("statement", "short"))


if __name__ == "__main__":
    unittest.main()
