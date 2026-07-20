import { fetch as httpFetch } from "@tauri-apps/plugin-http";
import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { getClashApiSecret } from "../single/store";

const TRAFFIC_FLUSH_INTERVAL_MS = 250;
const MAX_STREAM_REMAINDER_BYTES = 256 * 1024;

// plugin-http 的 reqwest 默认读取系统代理（auto_sys_proxy=true）；在“不设置系统代理”模式下，
// 若机器已有外部代理，发往 127.0.0.1:9191 的请求会被带进代理而失败（reqwest 对回环地址无隐式豁免）。
// 加一个“永远被绕过的占位代理”会让 reqwest 置 auto_sys_proxy=false（等价 Rust 侧
// build_no_redirect_client 的 .no_proxy()），从而不再读取系统代理；noProxy 再把目标豁免为直连。
//
// noProxy 必须写 IP，不能用 "*"：hyper-util 的 matcher 对能解析成 IP 的 host 只查 IP 列表，
// 而 "*" 会被归入 domain 列表，对 127.0.0.1 这类 IP 目标永不命中，请求反而打到占位代理导致
// “error sending request”。占位 URL 仅为构造 Proxy 的必填项，因目标已被 noProxy 豁免而永不被连接。
const NO_SYSTEM_PROXY = {
  all: { url: "http://127.0.0.1:1", noProxy: "127.0.0.1, ::1, localhost" },
} as const;

async function getClashApiBaseUrl(): Promise<string> {
  const port = await invoke<number>("get_clash_api_port");
  return `http://127.0.0.1:${port}`;
}

// clash API（external controller）的统一入口：注入鉴权头并强制不走任何系统代理。
export async function clashApiFetch(
  path: string,
  init: NonNullable<Parameters<typeof httpFetch>[1]> = {},
) {
  const [secret, baseUrl] = await Promise.all([
    getClashApiSecret(),
    getClashApiBaseUrl(),
  ]);
  return httpFetch(`${baseUrl}${path}`, {
    ...init,
    proxy: NO_SYSTEM_PROXY,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      Authorization: `Bearer ${secret}`,
      ...init.headers,
    },
  });
}

// 流式流量接口沿用 webview 全局 fetch：浏览器对回环地址自动豁免代理，且 plugin-http
// 不适合 /traffic 这类无限分块流；故这里不经过 clashApiFetch。
async function fetchTraffic(signal?: AbortSignal) {
  const [secret, baseUrl] = await Promise.all([
    getClashApiSecret(),
    getClashApiBaseUrl(),
  ]);
  const response = await fetch(`${baseUrl}/traffic`, {
    signal,
    headers: {
      Authorization: `Bearer ${secret}`,
    },
  });
  if (!response.ok) throw new Error(`traffic_http_${response.status}`);
  return response;
}

type JsonFrameResult<T> = {
  values: T[];
  remainder: string;
};

/**
 * Extract newline-delimited JSON frames while preserving an incomplete trailing
 * frame for the next network chunk. The Clash endpoints are streams, so a
 * browser ReadableStream chunk is not a message boundary.
 */
export function consumeJsonFrames<T>(buffer: string): JsonFrameResult<T> {
  const lines = buffer.split(/\r?\n/);
  let remainder = lines.pop() ?? "";
  const values: T[] = [];

  for (const rawLine of lines) {
    const line = rawLine.trim().replace(/^data:\s*/, "");
    if (!line || line === "[DONE]") continue;
    try {
      values.push(JSON.parse(line) as T);
    } catch {
      // A newline marks this as a complete malformed frame. Drop it so
      // one bad log line cannot poison the rest of the stream.
      console.warn("Dropped malformed Clash stream frame");
    }
  }

  // Some Clash builds emit one JSON object per write without a trailing
  // newline. Parse it eagerly when complete; otherwise keep it buffered.
  const trimmedRemainder = remainder.trim();
  if (trimmedRemainder) {
    try {
      values.push(JSON.parse(trimmedRemainder) as T);
      remainder = "";
    } catch {
      // The frame may be split across chunks; retain it unchanged.
    }
  }

  // A malformed endpoint response without line breaks must not grow memory
  // without bound for the lifetime of the app. Traffic frames are tiny, so a
  // 256 KiB incomplete frame is necessarily corrupt and can be discarded.
  if (remainder.length > MAX_STREAM_REMAINDER_BYTES) {
    console.warn("Dropped oversized incomplete Clash stream frame");
    remainder = "";
  }

  return { values, remainder };
}

export interface NetworkSpeed {
  upload: number;
  download: number;
}

export const formatNetworkSpeed = (bytes: number): string => {
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  return `${value.toFixed(1)} ${units[unitIndex]}/s`;
};

export function useNetworkSpeed(enabled: boolean = true) {
  const [speed, setSpeed] = useState<NetworkSpeed>({ upload: 0, download: 0 });

  useEffect(() => {
    if (!enabled) {
      setSpeed((previous) => (
        previous.upload === 0 && previous.download === 0
          ? previous
          : { upload: 0, download: 0 }
      ));
      return;
    }

    const controller = new AbortController();
    let readerRef: ReadableStreamDefaultReader<Uint8Array> | null = null;
    let cancelled = false;
    let flushTimer: ReturnType<typeof setTimeout> | undefined;
    let pendingSpeed: NetworkSpeed | undefined;

    const flush = () => {
      flushTimer = undefined;
      if (cancelled) {
        pendingSpeed = undefined;
        return;
      }
      const next = pendingSpeed;
      pendingSpeed = undefined;
      if (!next) return;
      setSpeed((previous) => (
        previous.upload === next.upload && previous.download === next.download
          ? previous
          : next
      ));
    };

    const scheduleFlush = () => {
      if (!cancelled && flushTimer === undefined) {
        flushTimer = setTimeout(flush, TRAFFIC_FLUSH_INTERVAL_MS);
      }
    };

    const setup = async () => {
      try {
        const response = await fetchTraffic(controller.signal);
        const reader = response.body?.getReader();
        if (!reader) return;

        readerRef = reader;
        if (cancelled) {
          await reader.cancel();
          return;
        }
        const decoder = new TextDecoder();
        let remainder = "";

        while (!cancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          remainder += decoder.decode(value, { stream: true });
          const result = consumeJsonFrames<{ up: number; down: number }>(
            remainder,
          );
          remainder = result.remainder;
          const latest = result.values[result.values.length - 1];
          if (
            latest && Number.isFinite(latest.up) && Number.isFinite(latest.down)
          ) {
            pendingSpeed = { upload: latest.up, download: latest.down };
            scheduleFlush();
          }
        }
        if (!cancelled) flush();
      } catch (error) {
        if (!cancelled) {
          console.error("Failed to read Clash traffic stream:", error);
        }
      }
    };

    setup();

    return () => {
      cancelled = true;
      controller.abort();
      if (flushTimer !== undefined) clearTimeout(flushTimer);
      pendingSpeed = undefined;
      void readerRef?.cancel();
    };
  }, [enabled]);

  return speed;
}
