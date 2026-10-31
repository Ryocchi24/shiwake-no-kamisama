// 仕訳の神様 AIカメラの中継役（Cloudflare Workers）
// アプリから写真を受け取り、Anthropic API に渡して、読み取り結果（JSON）を返すだけ。
// キーは Cloudflare の「シークレット」に置く（このファイルにもGitHubにも書かない）。
//   ANTHROPIC_API_KEY … このアプリ専用のAPIキー
//   SHARED_TOKEN      … 合い言葉（お父さんの端末にだけ入れる）
// 任意: MODEL（既定 claude-haiku-5-5）、ALLOWED_ORIGINS（カンマ区切り）
// 写真や読み取り結果は、保存も記録もしない。

const DEFAULT_MODEL = "claude-haiku-5-5";
const DEFAULT_ORIGINS = ["https://ryocchi24.github.io", "capacitor://localhost", "ionic://localhost", "http://localhost:3001"];
const MAX_BODY = 8 * 1024 * 1024; // 写真1枚の上限（base64で約8MB）
const MEDIA = /^(image\/(jpeg|png|webp|gif)|application\/pdf)$/;

const PROMPTS = {
  receipt: `これは日本の領収書・レシートの写真です。書いてある内容だけを読み取り、次の形のJSONだけを返してください（説明文やコードの囲みは付けない）。
{"date":"YYYY-MM-DD または空","store":"店名（支店名まで）","tel":"電話番号（数字とハイフン）または空","invoiceNo":"T+13桁の登録番号または空","total":合計金額（税込・数字）,"payment":"cash|card|unknown","items":[{"name":"品名","amount":金額（数字）,"taxRate":"10|8軽|8|0"}],"text":"レシートに印字されている文字を、印字されている行のとおりに、改行で区切って全部書き写したもの"}
決まり:
- 読めない・書いていない項目は、推測せず空文字か null にする。
- 住所は店名や品名に入れない。
- 金額に円記号やカンマは付けない。値引きはマイナスの金額の行にする。
- text は、上から下へ、店名・電話番号・登録番号・日付・品物・小計・税の内訳・合計・支払方法まで、見えるとおりに書き写す。
- 令和・平成の年は西暦に直す。`,
};

const json = (data, status, cors) => new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...cors } });

// 合い言葉の比較（時間のかかり方から推測されないように、全部の文字を見る）
function sameToken(a, b) {
  const x = new TextEncoder().encode(String(a || "")), y = new TextEncoder().encode(String(b || ""));
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// 返ってきた文章から、最初の { から対応する } までを取り出して読む
function extractJson(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inStr) { if (esc) esc = false; else if (ch === "\\") esc = true; else if (ch === '"') inStr = false; continue; }
    if (ch === '"') inStr = true;
    else if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) { try { return JSON.parse(text.slice(start, i + 1)); } catch { return null; } }
  }
  return null;
}

export default {
  async fetch(request, env) {
    const origins = (env.ALLOWED_ORIGINS ? env.ALLOWED_ORIGINS.split(",").map(s => s.trim()) : DEFAULT_ORIGINS);
    const origin = request.headers.get("Origin") || "";
    const cors = origins.includes(origin)
      ? { "Access-Control-Allow-Origin": origin, "Vary": "Origin", "Access-Control-Allow-Headers": "Content-Type, X-Shiwake-Token", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Max-Age": "86400" }
      : {};
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/read") return json({ error: "not_found" }, 404, cors);
    // 許可した画面（アプリ）からだけ受ける。ブラウザ以外（Originなし）は合い言葉だけで通す
    if (origin && !cors["Access-Control-Allow-Origin"]) return json({ error: "origin" }, 403, cors);
    if (!env.SHARED_TOKEN || !env.ANTHROPIC_API_KEY) return json({ error: "not_configured" }, 500, cors);
    if (!sameToken(request.headers.get("X-Shiwake-Token"), env.SHARED_TOKEN)) return json({ error: "token" }, 401, cors);

    const len = Number(request.headers.get("Content-Length") || 0);
    if (len > MAX_BODY) return json({ error: "too_large" }, 413, cors);
    let body;
    try { const text = await request.text(); if (text.length > MAX_BODY) return json({ error: "too_large" }, 413, cors); body = JSON.parse(text); }
    catch { return json({ error: "bad_request" }, 400, cors); }

    const m = /^data:([^;,]+);base64,(.+)$/s.exec(String(body.image || ""));
    if (!m || !MEDIA.test(m[1])) return json({ error: "bad_image" }, 400, cors);
    const prompt = PROMPTS[body.kind || "receipt"];
    if (!prompt) return json({ error: "bad_kind" }, 400, cors);

    const isPdf = m[1] === "application/pdf";
    const block = isPdf
      ? { type: "document", source: { type: "base64", media_type: m[1], data: m[2] } }
      : { type: "image", source: { type: "base64", media_type: m[1], data: m[2] } };
    let res;
    try {
      res = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: env.MODEL || DEFAULT_MODEL, max_tokens: 3000, messages: [{ role: "user", content: [block, { type: "text", text: prompt }] }] }),
      });
    } catch { return json({ error: "upstream_unreachable" }, 502, cors); }
    if (!res.ok) return json({ error: "upstream", status: res.status }, res.status === 429 ? 429 : 502, cors);

    const out = await res.json().catch(() => null);
    const text = (out?.content || []).filter(c => c.type === "text").map(c => c.text).join("");
    const data = extractJson(text);
    if (!data) return json({ error: "unreadable" }, 502, cors);
    return json({ ok: true, data, usage: out.usage ? { in: out.usage.input_tokens, out: out.usage.output_tokens } : undefined }, 200, cors);
  },
};
