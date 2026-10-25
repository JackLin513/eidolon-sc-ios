import { describe, expect, it } from "vitest";

import { eventText } from "@/lib/conversationEvents";

describe("对话事件的那句话", () => {
  it("挂断、结束对话写她的名字，送礼写上礼物名", () => {
    expect(eventText({ event: "hung_up", gift: null }, "真乃")).toBe("真乃挂断了电话");
    expect(eventText({ event: "ended", gift: null }, "真乃")).toBe("真乃结束了对话");
    expect(eventText({ event: "gift", gift: "蛋糕" }, "真乃")).toBe("你送给真乃一份蛋糕");
  });

  it("她不太舒服了：早 0、1、2 天写今天、昨天、前天，再早写那天的日期", () => {
    const since = (firstDay: string, daysAgo: number) =>
      eventText({ event: "unwell", gift: null, unwell: { firstDay, daysAgo } }, "真乃");

    expect(since("2026-10-24", 0)).toBe("真乃好像从今天起就不太舒服");
    expect(since("2026-10-23", 1)).toBe("真乃好像从昨天起就不太舒服");
    expect(since("2026-10-22", 2)).toBe("真乃好像从前天起就不太舒服");
    expect(since("2026-10-21", 3)).toBe("真乃好像从 10月21日 起就不太舒服");
  });
});
