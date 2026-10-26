"use client";

import { useEffect, useState } from "react";

import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { barImage, Sprite } from "@/components/play/bar/Sprite";
import { copy } from "@/i18n";

/** Where the original draws the bar's background (bg_bar), and the TV's screen and the fan on it. */
const ROOM = { x: 11, y: 18, width: 424, height: 257 };
const TV = { x: ROOM.x + 228, y: ROOM.y + 26, width: 99, height: 41 };
const FAN = { x: ROOM.x + 170, y: ROOM.y + 31 };

/** The TV's ten channels (bg_tv), each a name and its number of frames; the tenth is off. */
const CHANNELS: [string, number][] = [
  ["burrito", 3],
  ["wk", 7],
  ["dollar", 2],
  ["news", 6],
  ["yiik", 3],
  ["toku", 3],
  ["mwj", 4],
  ["hassy", 1],
  ["ramen", 3],
  ["", 0],
];
/** How long a frame of a channel stays, and how long 「ChN」 shows after a change (20 of the original's frames). */
const FRAME_MS = 220;
const CHANNEL_SHOWN_MS = 667;

/**
 * 吧台背景，最底下一层（.scratch/bar-room spec「画框和缩放」，坐标照原型 `pieces.tsx` 的 BarRoom）：
 * 背景图、转着的吊扇和电视。电视点一下换下一台，共 10 个台，第 10 台关机（黑屏）；换台时左上角亮一下绿字「ChN」。
 * 台号只记在这一次营业里（这个组件还在就记着），进来时随便停在开着的一台。
 */
export function BarRoom() {
  const [channel, setChannel] = useState(() => Math.floor(Math.random() * (CHANNELS.length - 1)));
  const [frame, setFrame] = useState(0);
  const [isChannelShown, setChannelShown] = useState(false);
  useEffect(() => {
    const id = window.setInterval(() => setFrame((n) => n + 1), FRAME_MS);
    return () => window.clearInterval(id);
  }, []);
  useEffect(() => {
    if (!isChannelShown) return;
    const id = window.setTimeout(() => setChannelShown(false), CHANNEL_SHOWN_MS);
    return () => window.clearTimeout(id);
  }, [isChannelShown, channel]);
  // 各台的图先载好，换台时不闪。
  useEffect(() => {
    for (const [name, frames] of CHANNELS) for (let i = 0; i < frames; i++) new Image().src = barImage(`ch_${name}_${i}`);
  }, []);

  const [name, frames] = CHANNELS[channel];
  const isOff = frames === 0;
  return (
    <>
      <Sprite name="barground" {...ROOM} />
      {isOff ? (
        <div className="absolute" style={{ left: TV.x, top: TV.y, width: TV.width, height: TV.height, background: BAR_INK.black }} />
      ) : (
        <Sprite name={`ch_${name}_${frame % frames}`} {...TV} />
      )}
      {isChannelShown && !isOff && (
        <PixelText x={TV.x + 5} y={TV.y + 2} runs={`Ch${channel + 1}`} color={BAR_INK.channel} mono label="" />
      )}
      <button
        type="button"
        aria-label={copy.bar.tv}
        className="bar-hit absolute"
        style={{ left: TV.x, top: TV.y, width: TV.width, height: TV.height }}
        onClick={() => {
          setChannel((c) => (c + 1) % CHANNELS.length);
          setChannelShown(true);
        }}
      />
      <Sprite name="fan" x={FAN.x} y={FAN.y} width={24} height={24} className="bar-fan" />
    </>
  );
}
