// Publishes the tab list to the Omarchy window gallery, and activates a tab
// when the gallery asks for one.
//
// The native port is deliberately long-lived: Firefox keeps this event page
// alive while a native port is open, which is what lets the gallery see an
// up-to-date tab list without polling.

const HOST = "omarchy_window_gallery";

let port = null;
let pushTimer = null;

function connect() {
  try {
    port = browser.runtime.connectNative(HOST);
  } catch (e) {
    console.error("window-gallery: cannot reach native host", e);
    return;
  }

  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    // The host exits when Firefox closes the port; if it dies while we are
    // running, back off and reconnect so the gallery does not go stale.
    port = null;
    setTimeout(connect, 2000);
  });

  pushTabs();
}

function onHostMessage(message) {
  if (!message || message.action !== "activate") return;
  const tabId = Number(message.tabId);
  const windowId = Number(message.windowId);
  if (!Number.isFinite(tabId)) return;

  browser.tabs.update(tabId, { active: true }).catch(() => {});
  if (Number.isFinite(windowId))
    browser.windows.update(windowId, { focused: true }).catch(() => {});
}

// Tab events arrive in bursts (a window opening fires many at once), so the
// push is coalesced rather than sent per event.
function schedulePush() {
  if (pushTimer !== null) return;
  pushTimer = setTimeout(() => {
    pushTimer = null;
    pushTabs();
  }, 150);
}

async function pushTabs() {
  if (!port) return;
  try {
    const tabs = await browser.tabs.query({});
    port.postMessage({
      action: "tabs",
      tabs: tabs.map(tab => ({
        id: tab.id,
        windowId: tab.windowId,
        title: tab.title || "",
        url: tab.url || "",
        active: tab.active === true,
        pinned: tab.pinned === true,
        audible: tab.audible === true,
        lastAccessed: tab.lastAccessed || 0
      }))
    });
  } catch (e) {
    console.error("window-gallery: could not read tabs", e);
  }
}

for (const event of [
  browser.tabs.onCreated, browser.tabs.onRemoved, browser.tabs.onUpdated,
  browser.tabs.onActivated, browser.tabs.onMoved, browser.tabs.onAttached,
  browser.tabs.onDetached
]) {
  event.addListener(schedulePush);
}

browser.windows.onFocusChanged.addListener(schedulePush);

connect();
