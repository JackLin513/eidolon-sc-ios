import { describe, expect, it } from "vitest";
import { distinctOffers, matchesOffer, matchesProvider, providerAt, type LLMOffer, type LLMProvider } from "@/lib/llmProviders";

const provider = (id: string, name: string, base_url: string | null = null): LLMProvider => ({
  id,
  name,
  protocol: base_url ? "chat-completions" : null,
  base_url,
});

const offer = (model: string, name: string): LLMOffer => ({
  model,
  name,
  protocol: "chat-completions",
  base_url: "https://llm.example/v1",
});

describe("matchesProvider", () => {
  it("matches the name and the id, in any case", () => {
    expect(matchesProvider(provider("deepseek", "DeepSeek"), "deeps")).toBe(true);
    expect(matchesProvider(provider("cline-pass", "ClinePass"), "CLINE")).toBe(true);
    expect(matchesProvider(provider("deepseek", "DeepSeek"), "openai")).toBe(false);
  });

  it("matches the Chinese names models.dev does not write", () => {
    expect(matchesProvider(provider("zhipuai-coding-plan", "Zhipu AI Coding Plan"), "智谱")).toBe(true);
    expect(matchesProvider(provider("volcengine-coding-plan", "Volcengine Ark Coding Plan"), "火山 套餐")).toBe(true);
    expect(matchesProvider(provider("volcengine", "Volcengine"), "套餐")).toBe(false);
    expect(matchesProvider(provider("google", "Google"), "gemini")).toBe(true);
  });

  it("matches every one when nothing is typed", () => {
    expect(matchesProvider(provider("deepseek", "DeepSeek"), "  ")).toBe(true);
  });
});

describe("matchesOffer", () => {
  it("matches the name and the model's id", () => {
    expect(matchesOffer(offer("glm-5.3", "GLM-5.3"), "glm 5.3")).toBe(true);
    expect(matchesOffer(offer("anthropic/claude-sonnet-5", "Claude Sonnet 5"), "anthropic/")).toBe(true);
    expect(matchesOffer(offer("glm-5.3", "GLM-5.3"), "qwen")).toBe(false);
  });
});

describe("providerAt", () => {
  const providers = [provider("google", "Google"), provider("deepseek", "DeepSeek", "https://api.deepseek.com")];

  it("finds the provider at an address, whatever its trailing slash and case", () => {
    expect(providerAt(providers, "https://API.deepseek.com/ ")?.id).toBe("deepseek");
  });

  it("finds none at an address no provider is at, nor at none", () => {
    expect(providerAt(providers, "https://relay.example/v1")).toBeUndefined();
    expect(providerAt(providers, "")).toBeUndefined();
  });
});

describe("distinctOffers", () => {
  it("keeps the first of a model listed twice", () => {
    expect(distinctOffers([offer("m", "First"), offer("n", "N"), offer("m", "Second")]).map((o) => o.name)).toEqual([
      "First",
      "N",
    ]);
  });
});
