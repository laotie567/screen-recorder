// 批注编辑器:加载宿主截图(分块读取)→ Canvas 批注 → 导出 PNG/复制剪贴板
(function () {
  const CHUNK = 750000; // 宿主 read-file 上限,保证 base64 后 < 1MB
  const MAX_UNDO = 30;

  const canvas = document.getElementById("canvas");
  const overlay = document.createElement("canvas");
  overlay.id = "overlay";
  canvas.parentElement.insertBefore(overlay, canvas.nextSibling);
  const ctx = canvas.getContext("2d");
  const octx = overlay.getContext("2d");

  let img = null; // 源图(用于模糊回读)
  let tool = "pen";
  let color = "#ef4444";
  let size = 4;
  let drawing = false;
  let startX = 0, startY = 0, lastX = 0, lastY = 0;
  let undoStack = [], redoStack = [];
  let activeText = null;

  // ---- 宿主调用(经 service worker 桥) ----
  function callHost(payload) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({ type: "host-call", payload }, (resp) => {
        if (chrome.runtime.lastError) return reject(new Error(chrome.runtime.lastError.message));
        if (resp && resp.ok) resolve(resp.resp);
        else reject(new Error((resp && resp.error) || "host error"));
      });
    });
  }

  // 分块读取本地文件 → data URL
  async function readFileAsDataURL(path) {
    let parts = [], offset = 0;
    for (;;) {
      const resp = await callHost({ cmd: "read-file", path, offset, size: CHUNK });
      parts.push(resp.data);
      if (resp.eof) break;
      offset += CHUNK;
    }
    return "data:image/png;base64," + parts.join("");
  }

  // ---- 状态与快照 ----
  function snapshot() {
    undoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height));
    if (undoStack.length > MAX_UNDO) undoStack.shift();
    redoStack = [];
  }
  function undo() {
    if (!undoStack.length) return;
    redoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height));
    ctx.putImageData(undoStack.pop(), 0, 0);
  }
  function redo() {
    if (!redoStack.length) return;
    undoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height));
    ctx.putImageData(redoStack.pop(), 0, 0);
  }

  function pos(e) {
    const r = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - r.left) * (canvas.width / r.width),
      y: (e.clientY - r.top) * (canvas.height / r.height),
    };
  }

  // ---- 绘制 ----
  function paintPreview(e) {
    const p = pos(e);
    octx.clearRect(0, 0, overlay.width, overlay.height);
    octx.strokeStyle = color;
    octx.fillStyle = color;
    octx.lineWidth = size;
    octx.lineCap = "round";
    octx.lineJoin = "round";

    if (tool === "pen") {
      octx.beginPath();
      octx.moveTo(lastX, lastY);
      octx.lineTo(p.x, p.y);
      octx.stroke();
      lastX = p.x; lastY = p.y;
    } else if (tool === "rect") {
      octx.strokeRect(startX, startY, p.x - startX, p.y - startY);
    } else if (tool === "arrow") {
      octx.beginPath();
      octx.moveTo(startX, startY);
      octx.lineTo(p.x, p.y);
      octx.stroke();
      const angle = Math.atan2(p.y - startY, p.x - startX);
      const head = Math.max(size * 3, 10);
      octx.beginPath();
      octx.moveTo(p.x, p.y);
      octx.lineTo(p.x - head * Math.cos(angle - 0.45), p.y - head * Math.sin(angle - 0.45));
      octx.moveTo(p.x, p.y);
      octx.lineTo(p.x - head * Math.cos(angle + 0.45), p.y - head * Math.sin(angle + 0.45));
      octx.stroke();
    } else if (tool === "blur") {
      // 直接在底层画布上把当前位置的源图区域以模糊方式烙入(幂等,拖动形成涂抹带)
      ctx.save();
      ctx.filter = "blur(12px)";
      const w = size * 10, h = size * 8;
      const x = p.x - w / 2, y = p.y - h / 2;
      ctx.drawImage(img, x, y, w, h, x, y, w, h);
      ctx.restore();
      lastX = p.x; lastY = p.y;
    }
  }

  function commit() {
    ctx.drawImage(overlay, 0, 0);
    octx.clearRect(0, 0, overlay.width, overlay.height);
  }

  // ---- 文字 ----
  function showTextInput(x, y) {
    if (activeText) commitText();
    const wrap = document.getElementById("text-input-wrap");
    const ta = document.getElementById("text-input");
    wrap.classList.remove("hidden");
    wrap.style.left = x + "px";
    wrap.style.top = y + "px";
    ta.value = "";
    activeText = { ta, wrap };
    ta.focus();
  }
  function commitText() {
    if (!activeText) return;
    const { ta, wrap } = activeText;
    const text = ta.value.trim();
    if (text) {
      ctx.font = `bold ${size * 5}px -apple-system, "PingFang SC", sans-serif`;
      ctx.fillStyle = color;
      ctx.textBaseline = "top";
      ctx.fillText(text, parseInt(wrap.style.left, 10), parseInt(wrap.style.top, 10));
    }
    wrap.classList.add("hidden");
    activeText = null;
  }

  // ---- 鼠标/指针 ----
  canvas.addEventListener("pointerdown", (e) => {
    if (tool === "text") {
      const p = pos(e);
      snapshot();
      showTextInput(p.x, p.y);
      return;
    }
    drawing = true;
    const p = pos(e);
    startX = lastX = p.x;
    startY = lastY = p.y;
    snapshot();
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!drawing) return;
    paintPreview(e);
  });
  canvas.addEventListener("pointerup", (e) => {
    if (!drawing) return;
    drawing = false;
    commit();
  });

  document.getElementById("text-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); commitText(); }
  });
  document.getElementById("text-input").addEventListener("blur", commitText);

  // ---- 工具栏 ----
  document.querySelectorAll("#toolbar .tool").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("#toolbar .tool").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      tool = btn.dataset.tool;
      canvas.style.cursor = tool === "text" ? "text" : "crosshair";
    });
  });
  document.getElementById("color").addEventListener("input", (e) => { color = e.target.value; });
  document.getElementById("size").addEventListener("input", (e) => { size = parseInt(e.target.value, 10); });
  document.getElementById("undo").addEventListener("click", undo);
  document.getElementById("redo").addEventListener("click", redo);
  document.getElementById("clear").addEventListener("click", () => {
    snapshot();
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0);
  });
  document.getElementById("close").addEventListener("click", () => window.close());

  // ---- 导出 ----
  function mergedBlob() {
    return new Promise((resolve, reject) => {
      const out = document.createElement("canvas");
      out.width = canvas.width;
      out.height = canvas.height;
      const o = out.getContext("2d");
      o.drawImage(canvas, 0, 0);
      o.drawImage(overlay, 0, 0);
      out.toBlob((b) => (b ? resolve(b) : reject(new Error("toBlob failed"))), "image/png");
    });
  }
  document.getElementById("download").addEventListener("click", async () => {
    try {
      const blob = await mergedBlob();
      const url = URL.createObjectURL(blob);
      const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
      await chrome.downloads.download({ url, filename: `批注-${stamp}.png` });
      setTimeout(() => URL.revokeObjectURL(url), 30000);
    } catch (e) {
      showError(String(e));
    }
  });
  document.getElementById("copy").addEventListener("click", async () => {
    try {
      const blob = await mergedBlob();
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
      flash("已复制到剪贴板");
    } catch (e) {
      showError("复制失败:" + e);
    }
  });

  // ---- 加载截图 ----
  function showError(msg) {
    const el = document.getElementById("error");
    el.textContent = msg;
    el.classList.remove("hidden");
  }
  function flash(msg) {
    const el = document.getElementById("error");
    el.textContent = msg;
    el.style.color = "#86efac";
    el.classList.remove("hidden");
    setTimeout(() => {
      el.classList.add("hidden");
      el.style.color = "";
    }, 1500);
  }

  (async () => {
    const params = new URLSearchParams(location.search);
    const path = params.get("img");
    if (!path) { showError("缺少截图路径参数"); return; }
    try {
      const dataUrl = await readFileAsDataURL(path);
      img = new Image();
      await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = () => reject(new Error("图片解码失败"));
        img.src = dataUrl;
      });
      canvas.width = img.width;
      canvas.height = img.height;
      overlay.width = img.width;
      overlay.height = img.height;
      ctx.drawImage(img, 0, 0);
      document.getElementById("loading").classList.add("hidden");
    } catch (e) {
      showError("加载截图失败:" + e.message + "\n请确认宿主已安装并授权屏幕录制。");
    }
  })();
})();
