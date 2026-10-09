// Sidekick's service worker: shows the Mac's push notifications and opens the thread on tap.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));

self.addEventListener("push", event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch {}
  const threadId = data.threadId || "";
  event.waitUntil(self.registration.showNotification(data.title || "Sidekick", {
    body: data.body || "",
    tag: threadId || "sidekick",
    data: { threadId },
    icon: "icon.png",
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const threadId = event.notification.data?.threadId || "";
  const url = new URL(threadId ? "./#" + encodeURIComponent(threadId) : "./", self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if ("focus" in client) {
        await client.focus();
        if (threadId) client.postMessage({ open: threadId });
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
