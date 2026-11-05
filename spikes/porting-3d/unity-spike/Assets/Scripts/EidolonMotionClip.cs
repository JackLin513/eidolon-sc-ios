using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

/// The flat `EULR` dump `spikes/porting-3d/harness` writes from
/// `eidolon.motion/1`: per bone, Euler degrees (and optional local position)
/// for every frame. This is the same curve set the iOS client plays.
public sealed class EidolonMotionClip
{
    public struct Track
    {
        public string Path;
        public bool HasPosition;
        public float[] Values;
    }

    public int Frames { get; private set; }
    public readonly List<Track> Tracks = new List<Track>();

    public static EidolonMotionClip Load(string path)
    {
        var clip = new EidolonMotionClip();
        using (var reader = new BinaryReader(File.OpenRead(path)))
        {
            if (new string(reader.ReadChars(4)) != "EULR")
                throw new InvalidDataException("not an EULR clip");
            clip.Frames = reader.ReadInt32();
            var count = reader.ReadInt32();
            for (var i = 0; i < count; i++)
            {
                var length = reader.ReadUInt16();
                var name = Encoding.UTF8.GetString(reader.ReadBytes(length));
                var hasPosition = reader.ReadByte() == 1;
                var values = new float[(hasPosition ? 6 : 3) * clip.Frames];
                for (var v = 0; v < values.Length; v++) values[v] = reader.ReadSingle();
                clip.Tracks.Add(new Track { Path = name, HasPosition = hasPosition, Values = values });
            }
        }
        return clip;
    }
}
