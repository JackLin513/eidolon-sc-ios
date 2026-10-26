// The bar's music and sound effects (.scratch/bar-room spec「声音和存储桶」): the list beside the
// character configuration (`characters/bar_audio.json`, copied here as `barAudio.json` since the
// frontend's image is built from `frontend/` alone), and what of it the stands' bucket has
// (`bar/manifest.json`). Original Ogg files: a browser that cannot play Ogg (Safari before 18.4)
// has no audio, as does a deployment whose bucket has none; the bar plays on in silence.

import catalog from "@/lib/barAudio.json";

export type BarTrack = { id: number; file: string; title: string };
export type BarAudioCatalog = {
  /** The jukebox's tracks, in its order; `id` is the original's sound number. */
  tracks: BarTrack[];
  /** The default playlist, by track id. */
  default_playlist: number[];
  sfx: { name: string; file: string }[];
};
/** `bar/manifest.json`: the track ids and sound effect names uploaded to the bucket. */
export type BarManifest = { tracks: number[]; sfx: string[] };
/** What the bar can play: the tracks in the jukebox's order, the default playlist, the sound effects. */
export type BarAudio = { tracks: BarTrack[]; playlist: number[]; sfx: string[] };

export const BAR_AUDIO: BarAudioCatalog = catalog;

/** What both the list and the bucket have, if the browser plays Ogg; nothing without a manifest. */
export function availableAudio(catalog: BarAudioCatalog, manifest: BarManifest | null, canPlayOgg: boolean): BarAudio {
  if (!manifest || !canPlayOgg) return { tracks: [], playlist: [], sfx: [] };
  const tracks = catalog.tracks.filter((t) => manifest.tracks.includes(t.id));
  const ids = new Set(tracks.map((t) => t.id));
  return {
    tracks,
    playlist: catalog.default_playlist.filter((id) => ids.has(id)),
    sfx: catalog.sfx.map((s) => s.name).filter((name) => manifest.sfx.includes(name)),
  };
}

/** `bar/manifest.json` as read; null for anything not one. */
export function parseManifest(value: unknown): BarManifest | null {
  if (typeof value !== "object" || value === null) return null;
  const { tracks, sfx } = value as Record<string, unknown>;
  const isListOf = (list: unknown, type: "number" | "string") =>
    Array.isArray(list) && list.every((item) => typeof item === type);
  return isListOf(tracks, "number") && isListOf(sfx, "string")
    ? { tracks: tracks as number[], sfx: sfx as string[] }
    : null;
}
