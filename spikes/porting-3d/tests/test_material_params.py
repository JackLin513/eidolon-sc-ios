"""The shader name only exists on the shader's parsed form, not on the pointer."""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from material_params import shader_name


class ShaderNameTests(unittest.TestCase):
    def test_reads_the_parsed_form_name(self):
        shader = SimpleNamespace(m_ParsedForm=SimpleNamespace(m_Name="Custom/Chr_Hair"))
        material = SimpleNamespace(m_Shader=SimpleNamespace(read=lambda: shader))

        self.assertEqual(shader_name(material), "Custom/Chr_Hair")

    def test_missing_shader_is_empty_not_an_error(self):
        def explode():
            raise ValueError("external reference")

        material = SimpleNamespace(m_Shader=SimpleNamespace(read=explode))

        self.assertEqual(shader_name(material), "")

    def test_unparsed_shader_is_empty(self):
        shader = SimpleNamespace(m_ParsedForm=None)
        material = SimpleNamespace(m_Shader=SimpleNamespace(read=lambda: shader))

        self.assertEqual(shader_name(material), "")


if __name__ == "__main__":
    unittest.main()
