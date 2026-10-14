// 釣果ボード：チャットのプッシュ通知を送る
// データベースの仕組み（notify_chat_push）から、新しいメッセージが入るたびに呼ばれます。
// 必要なシークレット：PUSH_HOOK_SECRET（呼び出し用の合言葉）、VAPID_PUBLIC_KEY・VAPID_PRIVATE_KEY（通知用の鍵）
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  try {
    if (req.headers.get("x-hook-secret") !== Deno.env.get("PUSH_HOOK_SECRET")) return json({ error: "forbidden" }, 403);
    const { message_id } = await req.json();

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: msg } = await db.from("chat_messages").select("id,user_id,kind,body").eq("id", message_id).maybeSingle();
    if (!msg || !["text", "photo"].includes(msg.kind)) return json({ skipped: true });

    const { data: sender } = await db.from("profiles").select("display_name").eq("id", msg.user_id).maybeSingle();
    const name = sender?.display_name ?? "メンバー";
    const text = msg.kind === "photo" ? "写真を送りました" : String(msg.body ?? "").slice(0, 100);

    // 送った本人以外の届け先
    const { data: subs } = await db.from("push_subscriptions").select("id,user_id,endpoint,p256dh,auth").neq("user_id", msg.user_id);
    if (!subs?.length) return json({ sent: 0 });

    webpush.setVapidDetails(
      "https://nakazu210.github.io/tsuri-board/",
      Deno.env.get("VAPID_PUBLIC_KEY")!,
      Deno.env.get("VAPID_PRIVATE_KEY")!,
    );

    // 人ごとに未読の数を数えて、アイコンの数字にする
    const unread: Record<string, number> = {};
    for (const uid of new Set(subs.map((s) => s.user_id))) {
      const { data: r } = await db.from("chat_reads").select("last_read_at").eq("user_id", uid).maybeSingle();
      let q = db.from("chat_messages").select("id", { count: "exact", head: true }).neq("user_id", uid).neq("kind", "catch");
      if (r?.last_read_at) q = q.gt("created_at", r.last_read_at);
      const { count } = await q;
      unread[uid] = count ?? 1;
    }

    let sent = 0;
    const gone: string[] = [];
    await Promise.all(subs.map(async (s) => {
      const payload = JSON.stringify({ title: name, body: text, badge: unread[s.user_id], url: "./?view=chat" });
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24 });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number })?.statusCode;
        if (code === 404 || code === 410) gone.push(s.id); // 使われなくなった届け先は消す
      }
    }));
    if (gone.length) await db.from("push_subscriptions").delete().in("id", gone);
    return json({ sent, removed: gone.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
