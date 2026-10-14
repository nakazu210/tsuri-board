// 釣果ボード：AI判定（写真から魚種・サイズ・匹数を推定する）
// Gemini API の鍵は Supabase のシークレット GEMINI_API_KEY に保存します（プログラムには書きません）。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const PROMPT = `あなたは日本の釣りに詳しい専門家です。写真に写っている釣果を判定してください。
- 魚種は日本で一般的な呼び名で答えてください（例：真鯛、チダイ、アジ、サバ、イワシ、キス、メバル、カサゴ、ハマチ、タチウオ、アオリイカ）。
- ケンサキイカ（白イカ）は species を「白イカ」としてください。
- 同じ魚種が複数写っていれば count に匹数を入れ、魚種ごとに1行にまとめてください。
- size_cm はその魚種で一番大きい個体の全長（cm）です。メジャーや定規が写っていれば目盛りを読み取ってください。比較できる物がなければ、手や道具の大きさから大まかに推定してください。分からなければ null にしてください。
- has_measure はメジャーや定規が写っているかどうかです。
- confidence は判定全体の自信（0〜1）です。似た魚（真鯛とチダイなど）で迷う場合は低めにしてください。
- note には判定で迷った点などを日本語で短く書いてください。
- 魚やイカが写っていなければ items を空にしてください。`;

const SCHEMA = {
  type: "OBJECT",
  properties: {
    items: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          species: { type: "STRING" },
          size_cm: { type: "NUMBER", nullable: true },
          count: { type: "INTEGER" },
        },
        required: ["species", "count"],
      },
    },
    confidence: { type: "NUMBER" },
    has_measure: { type: "BOOLEAN" },
    note: { type: "STRING" },
  },
  required: ["items", "confidence", "has_measure"],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("GEMINI_API_KEY");
    if (!key) return json({ error: "AIの設定がまだです（管理者に連絡してください）" }, 500);
    const model = Deno.env.get("GEMINI_MODEL") || "gemini-flash-latest";

    // ログイン中のメンバーだけが使える
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "ログインしてください" }, 401);
    const { data: me } = await admin.from("profiles").select("id").eq("id", user.id).maybeSingle();
    if (!me) return json({ error: "メンバーだけが使えます" }, 403);

    const { image } = await req.json();
    const b64 = String(image ?? "").replace(/^data:image\/\w+;base64,/, "");
    if (!b64 || b64.length > 4_000_000) return json({ error: "写真を読み込めませんでした" }, 400);

    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify({
          contents: [{ parts: [{ inline_data: { mime_type: "image/jpeg", data: b64 } }, { text: PROMPT }] }],
          generationConfig: { responseMimeType: "application/json", responseSchema: SCHEMA, temperature: 0.2 },
        }),
      },
    );
    const body = await res.json();
    if (!res.ok) {
      const msg = String(body?.error?.message ?? "");
      if (res.status === 429) return json({ error: "AIの利用回数の上限に達しました。少し時間をおいてお試しください" }, 429);
      return json({ error: "AIの判定に失敗しました：" + msg }, 502);
    }
    const text = body?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? "").join("") ?? "";
    const result = JSON.parse(text);
    result.items = (result.items ?? [])
      .filter((it: { species?: string; count?: number }) => it.species && Number(it.count) >= 1)
      .map((it: { species: string; size_cm?: number | null; count: number }) => ({
        species: String(it.species).trim(),
        size_cm: it.size_cm ? Math.round(Number(it.size_cm) * 2) / 2 : null,
        count: Math.max(1, Math.round(Number(it.count))),
      }));
    result.model = model;
    return json(result);
  } catch (e) {
    return json({ error: "AIの判定に失敗しました：" + String((e as Error)?.message ?? e) }, 500);
  }
});
