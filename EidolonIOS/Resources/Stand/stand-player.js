// Her stand's player (ADR-0017). Adapted from the upstream `StandEngine.ts`: it only
// plays, it does not decide anything. Swift sends one pose — which animation goes on
// each track and how long to mix — and this file plays it exactly as told.
//
// The patches the upstream engine carries for Spine 3.6 are all here: clips that never
// end (keepClipsEnding), `loop_start` and `relay` body animations, the mouth frozen on
// its first frame while shut, premultiplied alpha, and rebuilding after the WebGL
// context is lost.
(() => {
  "use strict";

  const post = (message) => {
    try {
      window.webkit.messageHandlers.stand.postMessage(message);
    } catch (error) {
      // Running outside the app (a plain browser); nothing to report to.
    }
  };

  const spine = window.spine;
  if (!spine) {
    post({ type: "unavailable", reason: "spine-webgl.js 没有提供 window.spine" });
    return;
  }

  // The tracks as the original ADV uses them: 0 body, 1 face, 2 nod, 3 gaze, 5 mouth
  // (4, her blush, is not used).
  const TRACK = { body: 0, face: 1, nod: 2, eye: 3, mouth: 5 };
  const MIX_SECONDS = 0.3;
  const MOUTH_MIX_SECONDS = 0.1;
  // At most this much time passes in one frame, so a dropped frame or coming back from
  // the background does not make the animation jump.
  const MAX_STEP_SECONDS = 0.1;

  // 60 frames a second and a pixel ratio of at most 2: measured upstream, more looks no
  // better and costs battery.
  const MAX_FPS = 60;
  const FRAME_MS = 1000 / MAX_FPS;
  const SLACK_MS = 1;
  const MAX_PIXEL_RATIO = 2;

  const UNPACK_PREMULTIPLY_ALPHA_WEBGL = 0x9241;

  /** Whether to draw in the display's animation frame at `now` (milliseconds). */
  class FrameGate {
    constructor() {
      this.due = Number.NEGATIVE_INFINITY;
    }

    shouldDraw(now) {
      if (now < this.due - SLACK_MS) return false;
      const next = this.due + FRAME_MS;
      this.due = next < now ? now + FRAME_MS : next;
      return true;
    }
  }

  /** The device's pixel ratio, but no more than `max`. */
  function pixelRatio(devicePixelRatio, max) {
    if (!(devicePixelRatio > 0)) return 1;
    return Math.min(devicePixelRatio, max);
  }

  /**
   * One outfit loaded and ready to draw: its skeleton, animation state, the animations
   * it has (name → duration in seconds), her range at rest, and which attachment the
   * clip workaround has seen.
   */
  class Pose {
    constructor(url, skeleton, data, state, animations, bounds) {
      this.url = url;
      this.skeleton = skeleton;
      this.data = data;
      this.state = state;
      this.animations = animations;
      this.bounds = bounds;
      this.clips = new Map();
      // What each track plays now, so a track is only reset when what it should play
      // changes. The body's entry is the animation name; `mouth` also carries open/shut.
      this.shown = { body: null, face: null, mouth: null, eye: null, nod: null };
    }
  }

  class StandEngine {
    constructor(canvas) {
      this.canvas = canvas;
      this.listeners = new AbortController();
      this.loaded = null;
      this.direction = null;
      this.camera = null;
      this.raf = 0;
      this.last = 0;
      this.paused = false;
      this.lost = false;
      this.disposed = false;
      this.loads = 0;
      this.wanted = null;
      this.fetching = new Map();
      this.gate = new FrameGate();

      const signal = this.listeners.signal;
      // Registered before the context is created: on restore the listeners run in
      // registration order, so premultiplied alpha is back on before the runtime
      // re-uploads its textures, or the restored stand has white edges.
      canvas.addEventListener(
        "webglcontextlost",
        (event) => {
          event.preventDefault();
          this.lost = true;
          this.stop();
          post({ type: "context-lost" });
        },
        { signal },
      );
      canvas.addEventListener(
        "webglcontextrestored",
        () => {
          this.gl.pixelStorei(UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
          this.lost = false;
          this.start();
          post({ type: "context-restored" });
        },
        { signal },
      );

      const context = new spine.webgl.ManagedWebGLRenderingContext(canvas, {
        alpha: true,
        premultipliedAlpha: true,
      });
      if (!context.gl) throw new Error("这台设备不支持 WebGL");
      this.gl = context.gl;
      this.lost = this.gl.isContextLost();
      // Premultiply alpha when uploading and draw as premultiplied, or some outfits
      // show white edges on her face and seams at the joints.
      this.gl.pixelStorei(UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
      this.renderer = new spine.webgl.SceneRenderer(canvas, context, true);
      this.assets = new spine.webgl.AssetManager(context);
    }

    /** Where the camera looks; Swift computes it from her bounds and the framing. */
    setCamera(camera) {
      this.camera = camera;
      if (this.loaded) this.start();
    }

    /**
     * Play this pose from now on. A pose that arrives before an outfit is remembered and
     * applied as soon as the outfit is drawn.
     */
    direct(direction) {
      this.direction = direction;
      if (this.loaded) this.follow(this.loaded);
    }

    setPaused(paused) {
      this.paused = paused;
      if (paused) this.stop();
      else this.start();
    }

    /**
     * Load one outfit and start drawing it with the current pose. Resolves with what the
     * player reports to Swift once it is drawn; rejects when her files cannot be read.
     * Only the last outfit asked for is switched to.
     */
    async load(url) {
      const ticket = ++this.loads;
      this.wanted = url;
      if (this.loaded && this.loaded.url === url) {
        if (this.camera) this.start();
        return this.report(this.loaded);
      }
      try {
        await this.fetchOutfit(url);
      } catch (error) {
        if (this.disposed) this.assets.dispose();
        else this.release(url);
        throw error;
      }
      if (this.disposed) {
        this.assets.dispose();
        return null;
      }
      if (ticket !== this.loads) {
        if (this.wanted !== url) this.release(url);
        return null;
      }
      let loaded;
      try {
        loaded = this.read(url);
      } catch (error) {
        this.release(url);
        throw error;
      }
      const previous = this.loaded;
      this.loaded = loaded;
      if (previous) this.release(previous.url);
      this.follow(this.loaded);
      if (this.camera) this.start();
      return this.report(loaded);
    }

    /** What Swift needs about a loaded outfit: its animations and her range at rest. */
    report(loaded) {
      return {
        type: "loaded",
        url: loaded.url,
        animations: Object.fromEntries(loaded.animations),
        bounds: loaded.bounds,
      };
    }

    /** Read a downloaded outfit, pose her at rest and measure her. */
    read(url) {
      const json = `${url}data.json`;
      const atlas = `${url}data.atlas`;
      const loader = new spine.AtlasAttachmentLoader(this.assets.get(atlas));
      const data = new spine.SkeletonJson(loader).readSkeletonData(this.assets.get(json));
      const skeleton = new spine.Skeleton(data);
      if (data.findSkin("normal")) skeleton.setSkinByName("normal");
      skeleton.setToSetupPose();
      skeleton.updateWorldTransform();
      const offset = new spine.Vector2();
      const size = new spine.Vector2();
      skeleton.getBounds(offset, size, []);
      const stateData = new spine.AnimationStateData(data);
      stateData.defaultMix = MIX_SECONDS;
      const animations = new Map(data.animations.map((animation) => [animation.name, animation.duration]));
      const bounds = { x: offset.x, y: offset.y, width: size.x, height: size.y };
      const state = new spine.AnimationState(stateData);
      return new Pose(url, skeleton, data, state, animations, bounds);
    }

    /**
     * Download an outfit's `data.json` and `data.atlas` (and its texture). The same
     * outfit asked for twice shares one download. Both must settle before reading on,
     * so a failure cannot upload a texture after the engine is gone.
     */
    fetchOutfit(url) {
      let fetching = this.fetching.get(url);
      if (!fetching) {
        fetching = Promise.allSettled([
          new Promise((resolve, reject) =>
            this.assets.loadText(`${url}data.json`, () => resolve(), (_, message) => reject(new Error(message))),
          ),
          new Promise((resolve, reject) =>
            this.assets.loadTextureAtlas(
              `${url}data.atlas`,
              () => resolve(),
              (_, message) => reject(new Error(message)),
            ),
          ),
        ])
          .then((results) => {
            for (const result of results) if (result.status === "rejected") throw result.reason;
          })
          .finally(() => this.fetching.delete(url));
        this.fetching.set(url, fetching);
      }
      return fetching;
    }

    /**
     * Release one outfit's assets. 3.6's `AssetManager.remove` only nulls the entry and
     * `removeAll` then calls dispose on null, so dispose here and drop the entry.
     * Disposing a texture takes it off the context's restore list; a second dispose of
     * an atlas' texture is a repeated delete, which WebGL ignores.
     */
    release(url) {
      const assets = this.assets.assets;
      for (const path of Object.keys(assets)) {
        if (!path.startsWith(url)) continue;
        const asset = assets[path];
        if (typeof asset === "object" && asset) asset.dispose?.();
        delete assets[path];
      }
    }

    /**
     * Put on each track what the current pose asks for, touching only the tracks whose
     * wish changed. A track whose animation this outfit lacks is left empty.
     */
    follow(loaded) {
      const want = this.direction;
      if (!want) return;
      const { state, shown } = loaded;

      if (shown.body !== want.body) {
        shown.body = want.body;
        this.playBody(loaded, want.body);
      }
      if (shown.face !== want.face) {
        shown.face = want.face;
        // An outfit without even `blank` empties the track, handing her face back to
        // the body animation.
        if (want.face && loaded.animations.has(want.face)) {
          state.setAnimation(TRACK.face, want.face, true);
        } else {
          state.setEmptyAnimation(TRACK.face, MIX_SECONDS);
        }
      }
      const mouth = want.mouth ? `${want.mouth.name} ${want.mouth.open ? "open" : "shut"}` : null;
      if (shown.mouth !== mouth) {
        shown.mouth = mouth;
        if (want.mouth) {
          // A shut mouth is the same talking animation frozen on frame 0, as upstream:
          // `lip_*_s` does not drive the mouth's mesh and the body's mouth would keep
          // moving. Freeze with `animationEnd = 0`, not `timeScale = 0`, because 3.6
          // mixes by timeScale and would otherwise never finish the mix.
          const entry = state.setAnimation(TRACK.mouth, want.mouth.name, want.mouth.open);
          entry.mixDuration = MOUTH_MIX_SECONDS;
          if (!want.mouth.open) entry.animationEnd = 0;
        } else {
          state.setEmptyAnimation(TRACK.mouth, MOUTH_MIX_SECONDS);
        }
      }
      if (shown.eye !== want.eye) {
        shown.eye = want.eye;
        if (want.eye && loaded.animations.has(want.eye)) {
          state.setAnimation(TRACK.eye, want.eye, true);
        } else {
          state.setEmptyAnimation(TRACK.eye, MIX_SECONDS);
        }
      }
      if (want.nod && shown.nod !== want.nod.id) {
        shown.nod = want.nod.id;
        if (loaded.animations.has(want.nod.name)) {
          // Play a nod once, then clear the track: `yes` does not end in a neutral pose.
          // Clear only after it has played: 3.6's `addEmptyAnimation` with delay 0
          // subtracts the mix time twice and eats the last 0.6 s of the nod.
          const nod = state.setAnimation(TRACK.nod, want.nod.name, false);
          state.addEmptyAnimation(TRACK.nod, MIX_SECONDS, nod.animation.duration);
        }
      }
    }

    /**
     * Change the body animation. One with a `loop_start` event plays its start once and
     * then loops from that event; without one it loops whole. Leaving an animation with
     * a `relay` event first plays the `arm_down*` it names, so a raised hand comes down.
     */
    playBody(loaded, name) {
      const { state, data, animations } = loaded;
      if (!animations.has(name)) return;
      const current = state.getCurrent(TRACK.body);
      if (current && current.animation.name === name) return;
      const relay = current && this.event(data, current.animation.name, "relay");
      let entry;
      if (relay && animations.has(relay.value)) {
        state.setAnimation(TRACK.body, relay.value, false);
        entry = state.addAnimation(TRACK.body, name, false, 0);
      } else {
        entry = state.setAnimation(TRACK.body, name, false);
      }
      const loopStart = this.event(data, name, "loop_start");
      if (!loopStart) {
        entry.loop = true;
        return;
      }
      entry.listener = {
        complete: (played) => {
          if (played.loop) return;
          played.loop = true;
          played.animationStart = loopStart.time;
          played.trackTime = 0;
        },
      };
    }

    /** The first event called `eventName` in animation `name`: its time and string value. */
    event(data, name, eventName) {
      const animation = data.findAnimation(name);
      for (const timeline of (animation && animation.timelines) || []) {
        if (!(timeline instanceof spine.EventTimeline)) continue;
        for (const event of timeline.events) {
          if (event.data.name === eventName) {
            return { time: event.time, value: event.stringValue || event.data.stringValue || "" };
          }
        }
      }
      return null;
    }

    start() {
      if (this.raf || !this.loaded || !this.camera || this.paused || this.lost || this.disposed) return;
      this.last = 0;
      this.raf = requestAnimationFrame(this.frame);
    }

    stop() {
      cancelAnimationFrame(this.raf);
      this.raf = 0;
    }

    frame = (now) => {
      this.raf = requestAnimationFrame(this.frame);
      if (!this.gate.shouldDraw(now)) return;
      const step = this.last ? Math.min((now - this.last) / 1000, MAX_STEP_SECONDS) : 0;
      this.last = now;
      if (this.loaded) this.draw(this.loaded, step);
    };

    draw(loaded, step) {
      const { canvas, gl, renderer } = this;
      const ratio = pixelRatio(window.devicePixelRatio, MAX_PIXEL_RATIO);
      const width = Math.max(1, Math.round(canvas.clientWidth * ratio));
      const height = Math.max(1, Math.round(canvas.clientHeight * ratio));
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      gl.viewport(0, 0, width, height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);

      loaded.state.update(step);
      loaded.state.apply(loaded.skeleton);
      loaded.skeleton.updateWorldTransform();
      this.keepClipsEnding(loaded);

      const camera = renderer.camera;
      camera.position.x = this.camera.x;
      camera.position.y = this.camera.y;
      camera.setViewport(this.camera.viewportWidth, this.camera.viewportHeight);
      renderer.begin();
      renderer.drawSkeleton(loaded.skeleton, true);
      renderer.end();
    }

    /**
     * Work around a clip bug in spine-ts 3.6 without touching the runtime: the renderer
     * skips slots without an attachment, and with them the "clip ends here" check. When
     * the end slot has no attachment at that moment, the clip never ends and everything
     * drawn after it is cut away (304 of 2215 outfits do this at rest). Each frame point
     * the end slot at the last slot that actually draws something between the clip and
     * its end slot; when nothing in that range draws, take the clipping attachment off
     * for this frame (and again whenever an animation puts it back).
     */
    keepClipsEnding(loaded) {
      const { ClippingAttachment, RegionAttachment, MeshAttachment } = spine;
      const { skeleton, clips } = loaded;
      for (const slot of skeleton.slots) {
        const attachment = slot.getAttachment();
        if (attachment instanceof ClippingAttachment && attachment.endSlot && !clips.has(attachment)) {
          clips.set(attachment, { slot, end: attachment.endSlot, detached: false });
        }
      }
      const order = skeleton.drawOrder;
      for (const [clip, state] of clips) {
        const current = state.slot.getAttachment();
        if (current !== clip && !(state.detached && current === null)) {
          // An animation put another attachment on this slot: it is not ours any more.
          state.detached = false;
          continue;
        }
        const from = order.indexOf(state.slot);
        const to = order.findIndex((slot) => slot.data === state.end);
        if (from < 0 || to < 0) continue;
        let last = null;
        for (let index = to; index > from; index--) {
          const drawn = order[index].getAttachment();
          if (drawn instanceof RegionAttachment || drawn instanceof MeshAttachment) {
            last = order[index].data;
            break;
          }
        }
        if (last) {
          clip.endSlot = last;
          if (state.detached) state.slot.setAttachment(clip);
          state.detached = false;
        } else {
          state.slot.setAttachment(null);
          state.detached = true;
        }
      }
    }

    dispose() {
      if (this.disposed) return;
      this.disposed = true;
      this.stop();
      this.listeners.abort();
      this.loaded = null;
      this.assets.dispose();
      this.renderer.dispose();
    }
  }

  let engine;
  try {
    engine = new StandEngine(document.getElementById("stand"));
  } catch (error) {
    post({ type: "unavailable", reason: String((error && error.message) || error) });
    return;
  }

  window.standPlayer = {
    /** The only entry point Swift calls: one JSON command per message. */
    receive(message) {
      if (!message || typeof message !== "object") return;
      try {
        switch (message.type) {
          case "camera":
            engine.setCamera(message.camera);
            break;
          case "pose":
            engine.direct(message.pose);
            break;
          case "paused":
            engine.setPaused(Boolean(message.paused));
            break;
          case "load":
            engine
              .load(message.url)
              .then((report) => {
                if (report) post(report);
              })
              .catch((error) => {
                post({ type: "failed", url: message.url, message: String((error && error.message) || error) });
              });
            break;
          default:
            break;
        }
      } catch (error) {
        post({ type: "failed", message: String((error && error.message) || error) });
      }
    },
  };

  post({ type: "ready" });
})();
