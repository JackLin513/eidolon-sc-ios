"use client";

import { useEffect, useState } from "react";

import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
  ComboboxSelectTrigger,
} from "@/components/ui/combobox";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
import { copy } from "@/i18n";
import { getLLMProviderModels, getLLMProviders } from "@/lib/api";
import {
  distinctOffers,
  matchesOffer,
  matchesProvider,
  providerAt,
  type LLMOffer,
  type LLMProvider,
} from "@/lib/llmProviders";
import type { LLMProtocol } from "@/lib/localOwnKeys";

const t = copy.llmPicker;

/** 下拉框里「手动填写」用这个值（下拉框的值不用空字符串）。 */
const MANUAL = "manual";

/** 选了服务商或模型后要填进表单的几项；没有的项不改。 */
export type LLMPick = { protocol?: LLMProtocol; base_url?: string; model?: string };

// 服务商列表整页只拉一次；每家的模型拉过就留着。拉失败的不留，下次打开表单再试。
let providersRequest: Promise<LLMProvider[]> | null = null;
const modelsRequests = new Map<string, Promise<LLMOffer[]>>();

function loadProviders(): Promise<LLMProvider[]> {
  providersRequest ??= getLLMProviders().catch(() => {
    providersRequest = null;
    return [];
  });
  return providersRequest;
}

function loadModels(provider: string): Promise<LLMOffer[]> {
  let request = modelsRequests.get(provider);
  if (!request) {
    request = getLLMProviderModels(provider).catch(() => {
      modelsRequests.delete(provider);
      return [];
    });
    modelsRequests.set(provider, request);
  }
  return request;
}

/**
 * 选服务商和模型（ADR-0027），放在接口协议、地址和模型名几项的上面：选了服务商就填好协议和地址，
 * 再选模型就填好模型名（连同这个模型自己的协议和地址）。几项照样能手改，存的也只是那几项。
 * 正在填的地址正好是某家的默认地址时，就显示那一家，所以修改已存的 LLM 时也能接着选模型。
 * 拉不到服务商列表（服务器还没拉到 models.dev）时什么都不显示，照旧手填。
 */
export function LLMProviderPicker({
  id,
  baseUrl,
  model,
  onPick,
}: {
  id: string;
  /** 表单里正在填的地址和模型名。 */
  baseUrl: string;
  model: string;
  onPick: (pick: LLMPick) => void;
}) {
  const [providers, setProviders] = useState<LLMProvider[]>([]);
  // 自己选的那家，连同选的时候的地址：地址被改成别的以后，改按地址认。
  const [chosen, setChosen] = useState<{ id: string; at: string } | null>(null);
  const [offers, setOffers] = useState<{ provider: string; list: LLMOffer[] } | null>(null);

  useEffect(() => {
    let current = true;
    loadProviders().then((list) => current && setProviders(list));
    return () => {
      current = false;
    };
  }, []);

  const guessed = providerAt(providers, baseUrl)?.id ?? MANUAL;
  const provider = chosen && chosen.at === baseUrl ? chosen.id : guessed;

  useEffect(() => {
    if (provider === MANUAL) return;
    let current = true;
    loadModels(provider).then((list) => current && setOffers({ provider, list: distinctOffers(list) }));
    return () => {
      current = false;
    };
  }, [provider]);

  if (providers.length === 0) return null;

  const byId = new Map(providers.map((p) => [p.id, p]));
  const listed = offers?.provider === provider ? offers.list : [];
  const byModel = new Map(listed.map((o) => [o.model, o]));

  function chooseProvider(next: string) {
    const picked = byId.get(next);
    if (!picked) {
      setChosen({ id: MANUAL, at: baseUrl });
      return;
    }
    // 换了一家，原来的模型名多半不对了，清掉；这家没写默认地址时，等选模型再填。
    const at = picked.base_url ?? baseUrl;
    setChosen({ id: picked.id, at });
    onPick({ ...(picked.base_url && picked.protocol && { base_url: at, protocol: picked.protocol }), model: "" });
  }

  function chooseModel(next: string) {
    const offer = byModel.get(next);
    if (!offer) return;
    setChosen({ id: provider, at: offer.base_url });
    onPick({ protocol: offer.protocol, base_url: offer.base_url, model: offer.model });
  }

  return (
    <>
      <Field>
        <FieldLabel htmlFor={`${id}-provider`}>{t.provider}</FieldLabel>
        <Combobox
          items={[MANUAL, ...providers.map((p) => p.id)]}
          itemToStringLabel={(value: string) => byId.get(value)?.name ?? t.manual}
          filter={(value: string, query: string) => {
            const p = byId.get(value);
            return p ? matchesProvider(p, query) : true;
          }}
          value={provider}
          onValueChange={(value) => value && chooseProvider(value)}
        >
          <ComboboxSelectTrigger id={`${id}-provider`} className="w-full" />
          <ComboboxContent>
            <ComboboxInput showTrigger={false} placeholder={t.search} />
            <ComboboxEmpty>{t.noProvider}</ComboboxEmpty>
            <ComboboxList>
              {(value: string) => (
                <ComboboxItem key={value} value={value}>
                  {byId.get(value)?.name ?? t.manual}
                </ComboboxItem>
              )}
            </ComboboxList>
          </ComboboxContent>
        </Combobox>
        <FieldDescription>{t.providerHint}</FieldDescription>
      </Field>
      {listed.length > 0 && (
        <Field>
          <FieldLabel htmlFor={`${id}-offer`}>{t.model}</FieldLabel>
          <Combobox
            items={listed.map((o) => o.model)}
            itemToStringLabel={(value: string) => byModel.get(value)?.name ?? value}
            filter={(value: string, query: string) => {
              const o = byModel.get(value);
              return o ? matchesOffer(o, query) : false;
            }}
            value={byModel.has(model.trim()) ? model.trim() : null}
            onValueChange={(value) => value && chooseModel(value)}
          >
            <ComboboxSelectTrigger id={`${id}-offer`} className="w-full" placeholder={t.modelPlaceholder} />
            <ComboboxContent>
              <ComboboxInput showTrigger={false} placeholder={t.modelSearch} />
              <ComboboxEmpty>{t.noModel}</ComboboxEmpty>
              <ComboboxList>
                {(value: string) => {
                  const offer = byModel.get(value);
                  return (
                    <ComboboxItem key={value} value={value}>
                      <span className="flex min-w-0 flex-col">
                        <span className="truncate">{offer?.name ?? value}</span>
                        {offer && offer.name !== offer.model && (
                          <span className="truncate text-meta text-muted-foreground">{offer.model}</span>
                        )}
                      </span>
                    </ComboboxItem>
                  );
                }}
              </ComboboxList>
            </ComboboxContent>
          </Combobox>
          <FieldDescription>{t.modelHint}</FieldDescription>
        </Field>
      )}
    </>
  );
}
