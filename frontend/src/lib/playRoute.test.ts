import { describe, expect, it } from "vitest";

import { playHref, playRedirect, playSubpage } from "@/lib/playRoute";

describe("the play page's addresses", () => {
  it("has a first level and a subpage for each card", () => {
    expect(playHref()).toBe("/play");
    expect(playHref("gifts")).toBe("/play/gifts");
    expect(playHref("tasks")).toBe("/play/tasks");
  });

  it("tells which subpage a path is", () => {
    expect(playSubpage("/play/gifts")).toBe("gifts");
    expect(playSubpage("/play/tasks")).toBe("tasks");
    expect(playSubpage("/play/calendar")).toBe("calendar");
    expect(playSubpage("/play")).toBeNull();
    expect(playSubpage("/play/xxx")).toBeNull();
    expect(playSubpage("/play/gifts/more")).toBeNull();
  });
});

describe("old and unknown play addresses", () => {
  it("sends the old gifts page to the gifts subpage", () => {
    expect(playRedirect("/gifts")).toBe("/play/gifts");
  });

  it("takes the preselected character, and any other parameter, along", () => {
    expect(playRedirect("/gifts?to=mano")).toBe("/play/gifts?to=mano");
    expect(playRedirect("/gifts?to=mano&x=1")).toBe("/play/gifts?to=mano&x=1");
  });

  it("sends a subpage we do not know to the first level", () => {
    expect(playRedirect("/play/xxx")).toBe("/play");
    expect(playRedirect("/play/gifts/more")).toBe("/play");
  });

  it("leaves the first level, the subpages and other addresses alone", () => {
    expect(playRedirect("/play")).toBeNull();
    expect(playRedirect("/play/gifts")).toBeNull();
    expect(playRedirect("/play/gifts?to=mano")).toBeNull();
    expect(playRedirect("/play/tasks")).toBeNull();
    expect(playRedirect("/play/calendar")).toBeNull();
    expect(playRedirect("/gifts/cake")).toBeNull();
    expect(playRedirect("/conversations")).toBeNull();
    expect(playRedirect("/player")).toBeNull();
  });
});
