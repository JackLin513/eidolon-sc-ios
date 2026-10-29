import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from unity_mesh import (
    Channel,
    decode_channel,
    decode_triangles,
    flip_handedness,
)


class DecodeChannelTests(unittest.TestCase):
    def test_reads_three_floats_per_vertex_at_the_channel_offset(self) -> None:
        data = struct.pack("<3f", 1.0, 2.0, 3.0) + struct.pack("<3f", 4.0, 5.0, 6.0)
        channel = Channel(dimension=3, format=0, offset=0, stream=0)

        values = decode_channel(data, stride=12, vertex_count=2, channel=channel)

        self.assertEqual(values, [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)])

    def test_honours_a_channel_that_starts_part_way_into_the_stride(self) -> None:
        # stride 6: one UNorm8x4 colour then a Float32x2 uv
        data = b"\xff\x00\x00\xff" + struct.pack("<2f", 0.5, 0.25)
        channel = Channel(dimension=2, format=0, offset=4, stream=1)

        values = decode_channel(data, stride=12, vertex_count=1, channel=channel)

        self.assertEqual(values, [(0.5, 0.25)])

    def test_decodes_32_bit_bone_indices(self) -> None:
        # MLTD stores BLENDINDICES as SInt32x4 after the Float32x4 weights.
        data = struct.pack("<4i", 1, 2, 3, 0)
        channel = Channel(dimension=4, format=11, offset=0, stream=2)

        values = decode_channel(data, stride=16, vertex_count=1, channel=channel)

        self.assertEqual(values, [(1, 2, 3, 0)])

    def test_reads_an_empty_channel_as_no_vertices(self) -> None:
        channel = Channel(dimension=0, format=0, offset=0, stream=0)

        self.assertEqual(decode_channel(b"", stride=0, vertex_count=3, channel=channel), [])


class DecodeTrianglesTests(unittest.TestCase):
    def test_splits_a_triangle_list_into_vertex_triples(self) -> None:
        indices = struct.pack("<6H", 0, 1, 2, 2, 1, 3)

        triangles = decode_triangles(indices, use_16bit=True)

        self.assertEqual(triangles, [(0, 1, 2), (2, 1, 3)])

    def test_splits_a_32_bit_index_buffer(self) -> None:
        indices = struct.pack("<3I", 5, 6, 7)

        self.assertEqual(decode_triangles(indices, use_16bit=False), [(5, 6, 7)])

    def test_drops_the_restart_index_and_starts_a_new_run(self) -> None:
        indices = struct.pack("<7H", 0, 1, 2, 0xFFFF, 3, 4, 5)

        triangles = decode_triangles(indices, use_16bit=True)

        self.assertEqual(triangles, [(0, 1, 2), (3, 4, 5)])


class FlipHandednessTests(unittest.TestCase):
    def test_negates_the_z_axis_of_positions_and_normals(self) -> None:
        positions = [(1.0, 2.0, 3.0)]
        normals = [(0.0, 0.0, 1.0)]

        flipped_positions, flipped_normals, _ = flip_handedness(positions, normals)

        self.assertEqual(flipped_positions, [(1.0, 2.0, -3.0)])
        self.assertEqual(flipped_normals, [(0.0, 0.0, -1.0)])

    def test_reverses_winding_so_the_faces_still_point_outwards(self) -> None:
        triangles = [(0, 1, 2), (3, 4, 5)]

        _, _, flipped = flip_handedness([], [], triangles)

        self.assertEqual(flipped, [(0, 2, 1), (3, 5, 4)])


if __name__ == "__main__":
    unittest.main()
