// Publishes the tab list and tab thumbnails to the Better Alt-Tab gallery,
// and activates a tab when the gallery asks for one.
//
// Thumbnails are captured when you LEAVE a tab, never on demand. A browser
// cannot render a tab it is not displaying -- background tabs get unloaded --
// so capturing on request would fail for exactly the tabs worth previewing.
// At the moment focus leaves a tab it is still rendered, so the capture always
// succeeds and shows the tab as you last saw it. It also costs one capture per
// switch rather than N per gallery open.

const HOST = "omarchy_window_gallery";

// ~500px wide is comfortably more than a gallery tile needs, and JPEG at this
// quality keeps a frame near 30KB.
const CAPTURE = { format: "jpeg", quality: 55, scale: 0.35 };
const LOAD_SETTLE_MS = 900;

let port = null;
let pushTimer = null;
let activeByWindow = new Map();
let loadTimers = new Map();

function connect() {
  try {
    port = browser.runtime.connectNative(HOST);
  } catch (e) {
    console.error("window-gallery: cannot reach native host", e);
    return;
  }

  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, 2000);
  });

  primeActiveTabs();
  pushTabs();
}

function onHostMessage(message) {
  if (!message) return;

  if (message.action === "reload") {
    browser.runtime.reload();
    return;
  }

  if (message.action !== "activate") return;
  const tabId = Number(message.tabId);
  const windowId = Number(message.windowId);
  if (!Number.isFinite(tabId)) return;

  browser.tabs.update(tabId, { active: true }).catch(() => {});
  if (Number.isFinite(windowId))
    browser.windows.update(windowId, { focused: true }).catch(() => {});
}

// Whatever is on screen right now is rendered, so it is the one set of tabs
// we can capture immediately on startup.
async function primeActiveTabs() {
  try {
    const tabs = await browser.tabs.query({ active: true });
    for (const tab of tabs) {
      activeByWindow.set(tab.windowId, tab.id);
      captureTab(tab.id);
    }
  } catch (e) {
    // Nothing to prime; thumbnails fill in as tabs are used.
  }
}

async function captureTab(tabId) {
  if (!port || !Number.isFinite(tabId)) return;
  try {
    const dataUrl = await browser.tabs.captureTab(tabId, CAPTURE);
    const comma = dataUrl.indexOf(",");
    if (comma < 0) return;
    port.postMessage({ action: "thumb", tabId, data: dataUrl.slice(comma + 1) });
  } catch (e) {
    // Discarded or not rendered: no thumbnail, and the gallery falls back to
    // the browser glyph. Not worth surfacing.
  }
}

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

// The tab being left is still rendered at this instant. This is the capture
// that matters.
browser.tabs.onActivated.addListener(({ tabId, windowId }) => {
  const leaving = activeByWindow.get(windowId);
  if (leaving !== undefined && leaving !== tabId) captureTab(leaving);
  activeByWindow.set(windowId, tabId);
  schedulePush();
});

// A tab that finishes loading while you are looking at it has content its
// thumbnail does not, so refresh once it settles.
browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  schedulePush();
  if (changeInfo.status !== "complete" || !tab.active) return;
  clearTimeout(loadTimers.get(tabId));
  loadTimers.set(tabId, setTimeout(() => {
    loadTimers.delete(tabId);
    captureTab(tabId);
  }, LOAD_SETTLE_MS));
});

browser.tabs.onRemoved.addListener(tabId => {
  if (port) port.postMessage({ action: "dropThumb", tabId });
  schedulePush();
});

// Leaving the browser entirely is also "leaving a tab".
browser.windows.onFocusChanged.addListener(windowId => {
  if (windowId === browser.windows.WINDOW_ID_NONE) {
    for (const tabId of activeByWindow.values()) captureTab(tabId);
  }
  schedulePush();
});

for (const event of [browser.tabs.onCreated, browser.tabs.onMoved,
                     browser.tabs.onAttached, browser.tabs.onDetached]) {
  event.addListener(schedulePush);
}

connect();
