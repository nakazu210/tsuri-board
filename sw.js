// 釣果ボード：通知の受け取り（スマホの裏側で動く部分）
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

// 通知が届いたとき：通知を表示し、ホーム画面のアイコンに未読の数を付ける
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || "釣果ボード", {
      body: d.body || "新しいメッセージがあります",
      icon: "images/icon-180.png",
      badge: "images/icon-180.png",
      tag: "chat",
      renotify: true,
      data: { url: d.url || "./?view=chat" },
    });
    if (self.navigator.setAppBadge && d.badge != null) {
      try { await self.navigator.setAppBadge(d.badge); } catch (_) {}
    }
  })());
});

// 通知を押したとき：アプリのチャット画面を開く
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "./?view=chat", self.registration.scope).href;
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if ("focus" in c) { c.postMessage({ type: "openChat" }); return c.focus(); }
    }
    return self.clients.openWindow(url);
  })());
});
