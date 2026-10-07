import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("boot flow", () => {
  it("join then immediate pause frames keep the clock moving", async () => {
    const res = await SELF.fetch("https://game.test/ws/boot-room", { headers: { Upgrade: "websocket" } });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    ws.accept();
    const frames: any[] = [];
    ws.addEventListener("message", (e: MessageEvent) => {
      if (typeof e.data === "string" && e.data !== "__pong") frames.push(JSON.parse(e.data));
    });
    ws.send(JSON.stringify({ type: "join", playerId: "ruth" }));
    // mimic the client: start button sends pause, then heartbeat pauses each second
    for (let i = 0; i < 6; i++) {
      ws.send(JSON.stringify({ type: "action", action: { type: "pause", dtMs: 450 } }));
      await scheduler.wait(80);
    }
    await scheduler.wait(500);
    const errs = frames.filter((f) => f.type === "error");
    const states = frames.filter((f) => f.type === "state");
    expect(errs).toEqual([]);
    expect(states.length).toBeGreaterThan(3);
    const last = states.at(-1);
    expect(last.view.t).toBeGreaterThan(1.5);
    ws.close();
  });
});
