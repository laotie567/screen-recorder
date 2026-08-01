// popup 控制面板:录制/截图/最近列表/状态
(function () {
  const $ = (id) => document.getElementById(id);

  let recording = false;
  let recordingTimer = null;

  // 页面消息 = service worker 的响应(请求-响应模型)或事件广播
  function callHost(payload) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({ type: "host-call", payload }, (resp) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }
        if (resp && resp.ok) resolve(resp.resp);
        else reject(new Error((resp && resp.error) || "host error"));
      });
    });
  }

  function fmtSize(bytes) {
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(0) + " KB";
    return (bytes / 1024 / 1024).toFixed(1) + " MB";
  }

  function fmtTime(ts) {
    const d = new Date(ts * 1000);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  function setError(text) {
    const box = $("error-box");
    if (text) {
      box.textContent = text;
      box.classList.remove("hidden");
    } else {
      box.classList.add("hidden");
    }
  }

  function permissionGuide(errorText) {
    if (errorText && errorText.includes("permission")) {
      return (
        "需要系统权限:\n1. 打开 系统设置 → 隐私与安全性\n2. 「屏幕录制」与「麦克风」中勾选 ScreenRecordHost\n3. 权限变更后需重启宿主(菜单栏图标 → 退出,再点录制自动拉起)\n\n" +
        errorText
      );
    }
    return errorText;
  }

  function renderRecordings() {
    callHost({ cmd: "list-recordings" })
      .then((resp) => {
        const items = resp.items || [];
        const list = $("recording-list");
        list.innerHTML = "";
        $("list-empty").classList.toggle("hidden", items.length > 0);
        items.slice(0, 10).forEach((item) => {
          const li = document.createElement("li");
          li.title = item.path;
          const name = document.createElement("span");
          name.className = "name";
          name.textContent = item.file;
          const meta = document.createElement("span");
          meta.className = "meta";
          meta.textContent = `${fmtSize(item.size)} · ${fmtTime(item.modified)}`;
          li.append(name, meta);
          li.addEventListener("click", () => {
            callHost({ cmd: "reveal-in-finder", path: item.path }).catch((e) =>
              setError(String(e))
            );
          });
          list.appendChild(li);
        });
      })
      .catch(() => {});
  }

  function refreshStatus() {
    callHost({ cmd: "status" })
      .then((resp) => {
        setRecording(resp.recording === true);
      })
      .catch((e) => {
        setRecording(false);
        $("status-text").textContent = "宿主未连接";
        setError(
          "无法连接本地宿主。请先运行 installer/install.sh 完成安装,并确认已加载扩展。"
        );
      });
  }

  function setRecording(on) {
    recording = on;
    const dot = $("status-dot");
    dot.className = "dot " + (on ? "recording" : "idle");
    $("status-text").textContent = on ? "录制中" : "就绪";
    $("recording-info").classList.toggle("hidden", !on);

    const btn = $("btn-record");
    btn.textContent = on ? "停止录制" : "开始录制";
    btn.classList.toggle("danger", on);
    btn.classList.toggle("primary", !on);

    if (on && !recordingTimer) {
      const start = Date.now();
      recordingTimer = setInterval(() => {
        const s = Math.floor((Date.now() - start) / 1000);
        const mm = String(Math.floor(s / 60)).padStart(2, "0");
        const ss = String(s % 60).padStart(2, "0");
        $("status-text").textContent = `录制中 ${mm}:${ss}`;
      }, 1000);
    } else if (!on && recordingTimer) {
      clearInterval(recordingTimer);
      recordingTimer = null;
    }
    $("btn-screenshot").disabled = on; // 录制中不可截图(避免抢权限弹窗)
  }

  // 事件广播:service worker → popup
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.event === "recording-started") {
      setRecording(true);
      renderRecordings();
    } else if (msg && msg.event === "recording-stopped") {
      setRecording(false);
      renderRecordings();
      // 文件已落盘(writer finishWriting 完成后才推送该事件)
      $("status-text").textContent = msg.file ? `已保存:${msg.file}` : "已停止";
    } else if (msg && msg.event === "recording-failed") {
      setRecording(false);
      setError(permissionGuide(msg.error));
    }
  });

  $("btn-record").addEventListener("click", () => {
    setError(null);
    if (recording) {
      callHost({ cmd: "stop-record" })
        .then(() => {
          setRecording(false);
          $("status-text").textContent = "停止中…"; // 落盘确认由 recording-stopped 事件驱动
        })
        .catch((e) => setError(String(e)));
    } else {
      callHost({ cmd: "start-record" })
        .then(() => setRecording(true))
        .catch((e) => setError(permissionGuide(String(e))));
    }
  });

  $("btn-screenshot").addEventListener("click", () => {
    setError(null);
    callHost({ cmd: "capture-screen" })
      .then((resp) => {
        const url =
          chrome.runtime.getURL("annotate/annotate.html") +
          "?img=" +
          encodeURIComponent(resp.path);
        chrome.tabs.create({ url });
        window.close();
      })
      .catch((e) => setError(permissionGuide(String(e))));
  });

  refreshStatus();
  renderRecordings();
})();
