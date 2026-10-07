// 釣果ボード：管理者用の機能（メンバーのアカウント作成・パスワードのリセット）
// Supabase の管理画面 →「Edge Functions」で、名前を admin-users にして、このファイルの中身を貼り付けます。
import { createClient } from "npm:@supabase/supabase-js@2";

const EMAIL_DOMAIN = "@tsuri.local";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // 呼び出した人が管理者か確認する
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "ログインしてください" }, 401);
    const { data: me } = await admin.from("profiles").select("role").eq("id", user.id).single();
    if (me?.role !== "admin") return json({ error: "管理者だけが使えます" }, 403);

    const body = await req.json();
    const password = String(body.password ?? "");
    if (password.length < 6) return json({ error: "パスワードは6文字以上にしてください" }, 400);

    if (body.action === "create") {
      const loginId = String(body.login_id ?? "").trim().toLowerCase();
      const displayName = String(body.display_name ?? "").trim();
      if (!/^[a-z0-9_-]{2,20}$/.test(loginId)) return json({ error: "IDは半角英数字2〜20文字で入力してください" }, 400);
      if (!displayName) return json({ error: "表示名を入力してください" }, 400);
      const { error } = await admin.auth.admin.createUser({
        email: loginId + EMAIL_DOMAIN,
        password,
        email_confirm: true,
        user_metadata: { display_name: displayName },
      });
      if (error) {
        const dup = /already|registered|exists/i.test(error.message);
        return json({ error: dup ? "このIDはすでに使われています" : error.message }, 400);
      }
      return json({ ok: true });
    }

    if (body.action === "reset") {
      const { error } = await admin.auth.admin.updateUserById(String(body.user_id), { password });
      if (error) return json({ error: error.message }, 400);
      // 次のログインで、本人に自分のパスワードを決めてもらう
      await admin.from("profiles").update({ must_change_password: true }).eq("id", String(body.user_id));
      return json({ ok: true });
    }

    return json({ error: "不明な操作です" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
