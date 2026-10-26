"use client";

import { type PointerEvent, useEffect, useRef, useState } from "react";

import { HitArea } from "@/components/play/bar/BarScreen";
import { Sprite } from "@/components/play/bar/Sprite";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { copy } from "@/i18n";
import { type BarSettings, gainOf, knobX, SLIDER, stepVolume, VOLUME_STEPS, volumeAt } from "@/lib/barSettings";

const t = copy.bar.settings;

/** The original's settings box, its 「全屏」 and 「窗口化」 rows cut out (`set_frame`), over the guest's window. */
const FRAME = { x: 95, y: 47, width: 258, height: 200 };
/** The original's sliders, their −/+ at either end (each 18 wide), from the box's left. */
const SLIDE = { x: FRAME.x + 39, width: 140, height: 17, end: 18 };
/** Each slider: its word over it, and where it is (the original's). */
const SLIDERS = {
  music: { label: "set_bgm", labelWidth: 55, labelY: FRAME.y + 42, slide: "set_bgm_slide", y: FRAME.y + 61 },
  sfx: { label: "set_sfx", labelWidth: 27, labelY: FRAME.y + 88, slide: "set_sfx_slide", y: FRAME.y + 107 },
} as const;
const LABEL_HEIGHT = 13;
/** The knob is 4×19, a pixel over the slider each way. */
const KNOB = { width: SLIDER.knobWidth, height: 19 };
/** 「扫描线 On/Off」 under 「图像」, and the white bar behind it under the mouse (the original's). */
const SCAN = { x: FRAME.x + 38, y: FRAME.y + 162, height: 14, bar: { x: FRAME.x + 31, y: FRAME.y + 160, width: 174, height: 22 } };
/** A slider that cannot be set is drawn faint. */
const FAINT = 0.35;

function Slider({
  which,
  value,
  isEnabled,
  onChange,
}: {
  which: keyof typeof SLIDERS;
  value: number;
  isEnabled: boolean;
  onChange: (value: number) => void;
}) {
  const at = SLIDERS[which];
  const name = t[which];
  const groove = useRef<HTMLDivElement>(null);
  const dim = isEnabled ? undefined : { opacity: FAINT };
  /** The volume under the pointer: the groove's hit area runs from the end of 「−」 to the start of 「+」. */
  const volumeUnder = (e: PointerEvent) => {
    const rect = groove.current!.getBoundingClientRect();
    const inner = SLIDE.width - 2 * SLIDE.end;
    return volumeAt(SLIDE.end + ((e.clientX - rect.left) / rect.width) * inner);
  };
  return (
    <>
      <Sprite name={at.label} x={SLIDE.x} y={at.labelY} width={at.labelWidth} height={LABEL_HEIGHT} style={dim} />
      <Sprite name={at.slide} x={SLIDE.x} y={at.y} width={SLIDE.width} height={SLIDE.height} style={dim} />
      <Sprite name="set_knob" x={SLIDE.x + knobX(value)} y={at.y - 1} {...KNOB} style={dim} />
      {isEnabled && (
        <>
          <HitArea x={SLIDE.x} y={at.y} width={SLIDE.end} height={SLIDE.height} label={t.quieter(name)} onClick={() => onChange(stepVolume(value, -1))} />
          <HitArea
            x={SLIDE.x + SLIDE.width - SLIDE.end}
            y={at.y}
            width={SLIDE.end}
            height={SLIDE.height}
            label={t.louder(name)}
            onClick={() => onChange(stepVolume(value, 1))}
          />
          <div
            ref={groove}
            role="slider"
            tabIndex={0}
            aria-label={name}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={value * 10}
            aria-valuetext={t.volume(name, value * 10)}
            className="bar-hit absolute"
            style={{ left: SLIDE.x + SLIDE.end, top: at.y - 1, width: SLIDE.width - 2 * SLIDE.end, height: KNOB.height }}
            onPointerDown={(e) => {
              e.currentTarget.setPointerCapture(e.pointerId);
              onChange(volumeUnder(e));
            }}
            onPointerMove={(e) => {
              if (e.currentTarget.hasPointerCapture(e.pointerId)) onChange(volumeUnder(e));
            }}
            onKeyDown={(e) => {
              const by = { ArrowLeft: -1, ArrowDown: -1, ArrowRight: 1, ArrowUp: 1, Home: -VOLUME_STEPS, End: VOLUME_STEPS }[e.key];
              if (by === undefined) return;
              e.preventDefault();
              onChange(stepVolume(value, by));
            }}
          />
        </>
      )}
    </>
  );
}

/**
 * 设置框（.scratch/bar-room 票 14）：原版中文版的设置框，裁掉「全屏」「窗口化」两行，盖在客人窗上。
 * 「声音」下面背景音乐（橙）、音效（蓝）两条原版的滑条：两头 −/+ 一次 10%，点滑条、拖滑块都行。改不了背景音乐音量的浏览器
 * （`canSetMusic`：iPhone 的 Safari）那一条淡着、点不动；取不到音频（`hasAudio`）时两条都是。
 * 「图像」下面「扫描线 On/Off」（原版的字图，鼠标停在上面时照原版反白），点了切换。
 * 点框外、按 Esc 关上（`onClose`）；侧边菜单在框外，再点「设置」也是点在框外。改了就交给 `onChange`，音量当场起作用；
 * 音效调了响一声 `buttonclick`，听得出多响。
 */
export function BarSettingsBox({
  settings,
  hasAudio,
  canSetMusic,
  sound,
  onChange,
  onClose,
}: {
  settings: BarSettings;
  hasAudio: boolean;
  canSetMusic: boolean;
  sound: BarSound;
  onChange: (patch: Partial<BarSettings>) => void;
  onClose: () => void;
}) {
  const [isHovered, setHovered] = useState(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const { play, setVolume } = sound;
  const scan = `set_scan_${settings.scanlines ? "on" : "off"}${isHovered ? "_hover" : ""}`;
  return (
    <>
      <HitArea x={0} y={0} width={640} height={360} label={t.close} onClick={onClose} />
      {/* 框里点空白处不关。 */}
      <div className="absolute" style={{ left: FRAME.x, top: FRAME.y, width: FRAME.width, height: FRAME.height }} />
      <Sprite name="set_frame" {...FRAME} />
      <Slider
        which="music"
        value={settings.music}
        isEnabled={hasAudio && canSetMusic}
        onChange={(music) => music !== settings.music && onChange({ music })}
      />
      <Slider
        which="sfx"
        value={settings.sfx}
        isEnabled={hasAudio}
        onChange={(sfx) => {
          if (sfx === settings.sfx) return;
          onChange({ sfx });
          // 先把增益改好再响，听到的就是新的音量。
          setVolume(gainOf(sfx));
          play("buttonclick");
        }}
      />
      {isHovered && <Sprite name="set_hover" {...SCAN.bar} />}
      <Sprite name={scan} x={SCAN.x} y={SCAN.y} width={settings.scanlines ? 98 : 100} height={SCAN.height} />
      <button
        type="button"
        aria-label={t.scanlines}
        aria-pressed={settings.scanlines}
        className="bar-hit absolute"
        style={{ left: SCAN.bar.x, top: SCAN.bar.y, width: SCAN.bar.width, height: SCAN.bar.height }}
        onPointerEnter={(e) => setHovered(e.pointerType === "mouse")}
        onPointerLeave={() => setHovered(false)}
        onClick={() => {
          onChange({ scanlines: !settings.scanlines });
          play("buttonclick");
        }}
      />
    </>
  );
}
