// 录屏批注助手 — Service Worker
// 职责:维护与本地宿主(ScreenRecordHost)的 native messaging 连接,
// 转发 popup/批注页的请求(串行队列),并把宿主事件(录制开始/停止等)广播给各页面。

const HOST_NAME = "com.screenrecord.host";

let port = null;

// 请求队列:宿主消息模型为串行请求/响应 + 异步事件,
// 并发请求排队逐个发送,避免"busy"拒绝。
const queue = [];
let inFlightReq = null;

function connect() {
  if (port) return true;
  let p;
  try {
    p = chrome.runtime.connectNative(HOST_NAME);
  } catch (e) {
    broadcast({ event: "host-error", error: String(e) });
    return false;
  }
  port = p;
  // 端口身份校验:Chrome 的 onMessage/onDisconnect 异步派发,
  // 旧端口(超时断开后)的回调可能迟到,不得影响新端口上的请求
  p.onMessage.addListener((msg) => {
    if (port !== p) return;
    if (msg && msg.event) {
      broadcast(msg);
      return;
    }
    // 请求响应
    const cur = inFlightReq;
    inFlightReq = null;
    if (cur) {
      clearTimeout(cur.timer);
      if (msg && msg.ok) cur.resolve(msg);
      else cur.reject(new Error((msg && msg.error) || "host error"));
    }
    pump();
  });
  p.onDisconnect.addListener(() => {
    if (port !== p) return;
    const err = chrome.runtime.lastError;
    port = null;
    if (inFlightReq) {
      const cur = inFlightReq;
      inFlightReq = null;
      clearTimeout(cur.timer);
      cur.reject(new Error(err ? err.message : "host disconnected"));
    }
    pump(); // 队列中的后续请求触发重连
    broadcast({ event: "host-disconnected" });
  });
  return true;
}

function pump() {
  if (inFlightReq || queue.length === 0) return;
  const req = queue.shift();
  if (!connect()) {
    req.reject(new Error("cannot connect to host"));
    pump();
    return;
  }
  inFlightReq = req;
  req.timer = setTimeout(() => {
    if (inFlightReq === req) {
      inFlightReq = null;
      req.reject(new Error("host timeout"));
      // 丢弃旧端口上可能迟到的响应:强制断开,下次请求走新连接
      if (port) {
        try { port.disconnect(); } catch (e) { /* ignore */ }
        port = null;
      }
      pump();
    }
  }, req.timeoutMs);
  try {
    port.postMessage(req.payload);
  } catch (e) {
    // 端口已失效(如超时后 disconnect):置 null 强制下次重连,避免整个队列被 reject
    port = null;
    inFlightReq = null;
    clearTimeout(req.timer);
    req.reject(e);
    pump();
  }
}

function hostCall(payload, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    queue.push({ payload, resolve, reject, timeoutMs, timer: null });
    pump();
  });
}

function broadcast(msg) {
  chrome.runtime.sendMessage(msg).catch(() => {});
}

// 页面请求:popup / 批注页通过 {type:"host-call", payload} 调用宿主
// 仅接受扩展自身页面(扩展页 URL 以 chrome-extension:// 开头且 host 为本扩展)
const EXT_URL_PREFIX = chrome.runtime.getURL("");

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "host-call") {
    if (!sender || !sender.url || !sender.url.startsWith(EXT_URL_PREFIX)) {
      sendResponse({ ok: false, error: "forbidden sender" });
      return false;
    }
    // 消息级超时:仅接受有限数值并钳制在 [1000, 60000] 毫秒
    let timeoutMs = Math.min(Math.max(typeof msg.timeoutMs === "number" && Number.isFinite(msg.timeoutMs) ? msg.timeoutMs : 10000, 1000), 60000);
    hostCall(msg.payload, timeoutMs)
      .then((resp) => sendResponse({ ok: true, resp }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true; // 异步响应
  }
  if (msg && msg.type === "host-status") {
    sendResponse({ connected: !!port });
    return false;
  }
  return false;
});
