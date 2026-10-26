"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { availableAudio, BAR_AUDIO, type BarAudio, parseManifest } from "@/lib/barAudio";

const NO_AUDIO: BarAudio = { tracks: [], playlist: [], sfx: [] };

/**
 * 酒吧的音效（.scratch/bar-room spec「声音和存储桶」）。进来时读一次存储桶的 `bar/manifest.json`，清单和它都有的、
 * 浏览器又放得了 Ogg 的才放（lib/barAudio）；读不到、放不了时一声不出，照常玩，不提示。
 *
 * - `audio`：能放什么；manifest 还在读时是 null，读不到、部署没给存储桶时什么都没有。曲目归点唱机（useBarJukebox）。
 * - `start()` 要在进门那一下点击里调：这一下建 `AudioContext`、让浏览器放行。这一页被点过以后（选曲界面上）
 *   第一次放音效时也会建。
 * - `play(name)` 放一次音效；`loop(name)` 无缝循环一个音效（Web Audio 的循环缓冲，`<audio>` 的 loop 有空隙），换一个或
 *   `loop(null)` 立刻停。音效第一次用到时才下载、解码，之后用缓冲区；manifest 还没读完时等它读完再放。
 * - 离开这一页（卸载）时全停。不放进 Service Worker 缓存，靠浏览器的 HTTP 缓存。
 */
export function useBarSound(base: string | null) {
  /** What can be played, once the manifest is read (nothing till then). */
  const available = useRef(NO_AUDIO);
  const [audio, setAudio] = useState<BarAudio | null>(base ? null : NO_AUDIO);
  /** Settles once the manifest is read, or could not be. */
  const isRead = useRef<Promise<unknown>>(Promise.resolve());
  const context = useRef<AudioContext | null>(null);
  const buffers = useRef(new Map<string, Promise<AudioBuffer | null>>());
  const looping = useRef<{ name: string | null; source: AudioBufferSourceNode | null }>({ name: null, source: null });

  useEffect(() => {
    if (!base) return;
    let isCurrent = true;
    const canPlayOgg = new Audio().canPlayType('audio/ogg; codecs="vorbis"') !== "";
    isRead.current = fetch(`${base}/manifest.json`)
      .then((res) => (res.ok ? res.json() : null))
      .then((body: unknown) => {
        if (isCurrent) available.current = availableAudio(BAR_AUDIO, parseManifest(body), canPlayOgg);
      })
      .catch(() => {})
      .then(() => {
        if (isCurrent) setAudio(available.current);
      });
    return () => {
      isCurrent = false;
    };
  }, [base]);

  // 离开这一页时全停。
  useEffect(() => {
    const bufferCache = buffers.current;
    return () => {
      looping.current = { name: null, source: null };
      void context.current?.close().catch(() => {});
      context.current = null;
      bufferCache.clear();
    };
  }, []);

  const start = useCallback(() => {
    if (!context.current) context.current = new AudioContext();
    void context.current.resume().catch(() => {});
  }, []);

  /** 音效的缓冲区：第一次用到时下载、解码；没有这个音效、下载或解码失败时是 null（失败的下次再试）。 */
  const buffer = useCallback(
    async (name: string): Promise<AudioBuffer | null> => {
      await isRead.current;
      // 这一页被点过（选曲界面上、从玩法页点进来）时，浏览器放行，不必等到进门。
      if (!context.current && navigator.userActivation?.hasBeenActive) start();
      const ctx = context.current;
      if (!ctx || !available.current.sfx.includes(name)) return null;
      let decoded = buffers.current.get(name);
      if (!decoded) {
        decoded = fetch(`${base}/sfx/${name}.ogg`)
          .then((res) => (res.ok ? res.arrayBuffer() : Promise.reject(new Error(String(res.status)))))
          .then((data) => ctx.decodeAudioData(data))
          .catch(() => {
            buffers.current.delete(name);
            return null;
          });
        buffers.current.set(name, decoded);
      }
      return decoded;
    },
    [base, start],
  );

  const sourceOf = (data: AudioBuffer, isLooping: boolean) => {
    const ctx = context.current!;
    const source = ctx.createBufferSource();
    source.buffer = data;
    source.loop = isLooping;
    source.connect(ctx.destination);
    source.start();
    return source;
  };

  const play = useCallback(
    (name: string) => {
      void buffer(name).then((data) => {
        if (data && context.current) sourceOf(data, false);
      });
    },
    [buffer],
  );

  const loop = useCallback(
    (name: string | null) => {
      const current = looping.current;
      if (current.name === name) return;
      current.source?.stop();
      looping.current = { name, source: null };
      if (!name) return;
      void buffer(name).then((data) => {
        // 解码完时已经换了、停了的不放。
        if (data && context.current && looping.current.name === name && !looping.current.source) {
          looping.current.source = sourceOf(data, true);
        }
      });
    },
    [buffer],
  );

  return useMemo(() => ({ audio, start, play, loop }), [audio, start, play, loop]);
}

export type BarSound = ReturnType<typeof useBarSound>;
