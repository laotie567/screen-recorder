// popup 控制面板:录制/截图/最近列表/状态
(function () {
  const $ = (id) => document.getElementById(id);

  let recording = false;
  let recordingTimer = null;
  let cameraActive = false; // 本次录制是否含摄像头画中画(状态文字展示用)
  let hostPath = ""; // 宿主可执行文件绝对路径(status 查询返回,权限添加时显示)

  // 摄像头开关:chrome.storage.local 持久化,下次打开 popup 记住选择
  const chkCamera = $("chk-camera");
  if (chrome.storage && chrome.storage.local) {
    chrome.storage.local.get({ cameraEnabled: false }, (cfg) => {
      chkCamera.checked = !!(cfg && cfg.cameraEnabled);
    });
    chkCamera.addEventListener("change", () => {
      chrome.storage.local.set({ cameraEnabled: chkCamera.checked });
    });
  }

  // 页面消息 = service worker 的响应(请求-响应模型)或事件广播
  function callHost(payload, timeoutMs) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage(
        { type: "host-call", payload, timeoutMs },
        (resp) => {
          if (chrome.runtime.lastError) {
            reject(new Error(chrome.runtime.lastError.message));
            return;
          }
          if (resp && resp.ok) resolve(resp.resp);
          else reject(new Error((resp && resp.error) || "host error"));
        }
      );
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
    if (errorText && errorText.includes("camera permission")) {
      return (
        "需要摄像头权限:\n" +
        "1. 打开 系统设置 → 隐私与安全性 → 摄像头\n" +
        "2. 勾选 ScreenRecordHost(找不到则用「+」按屏幕录制同样方式添加)\n" +
        "3. 授权后回来再点一次「开始录制」\n\n" +
        errorText
      );
    }
    if (errorText && errorText.includes("permission")) {
      return (
        "需要系统权限:\n" +
        "1. 打开 系统设置 → 隐私与安全性 → 屏幕录制\n" +
        "2. 若列表中有 ScreenRecordHost 直接勾选;\n" +
        "   若找不到 → 点「+」→ Cmd+Shift+G → 粘贴:\n" +
        "   " + (hostPath ? hostPath.replace(/\/Contents\/MacOS\/.*$/, ".app") : "~/Applications/ScreenRecordHost.app") + "\n" +
        "   (即 ScreenRecordHost.app 的路径)→ 打开 → 勾选\n" +
        "3. 「麦克风」同样操作\n" +
        "4. 授权后回这里再点一次「开始录制」:宿主会自动重启并生效\n" +
        "   (若仍报错,再点一次即可;不需要重启 Chrome)\n\n" +
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
    // 超时放宽到 25s:避免首次授权流程(最长 15s 弹窗等待)期间的状态查询排队超时
    callHost({ cmd: "status" }, 25000)
      .then((resp) => {
        if (resp && resp.hostPath) hostPath = resp.hostPath;
        cameraActive = resp && resp.camera === true;
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
        $("status-text").textContent =
          `录制中 ${mm}:${ss}` + (cameraActive ? "(含摄像头)" : "");
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
      cameraActive = msg.camera === true;
      setRecording(true);
      renderRecordings();
    } else if (msg && msg.event === "recording-stopped") {
      cameraActive = false;
      setRecording(false);
      renderRecordings();
      // 文件已落盘(writer finishWriting 完成后才推送该事件)
      $("status-text").textContent = msg.file ? `已保存:${msg.file}` : "已停止";
    } else if (msg && msg.event === "recording-failed") {
      cameraActive = false;
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
      // 首次录制可能触发系统授权弹窗;宿主内部最长路径 = 15s(SCShareableContent)
      // + 摄像头启动 + 20s(startCapture),超时放宽到 55 秒
      $("status-text").textContent = "正在请求录制…(如弹出系统授权窗请允许)";
      callHost({ cmd: "start-record", camera: chkCamera.checked }, 55000)
        .then((resp) => {
          cameraActive = chkCamera.checked && (!resp || resp.camera !== false);
          setRecording(true);
        })
        .catch((e) => {
          // 报错时顺带查询权限真实状态,区分"未授权"与"已授权但宿主需重试"
          callHost({ cmd: "check-permission" }, 10000)
            .then((perm) => {
              if (perm && perm.screenRecording === true) {
                if (perm.microphone !== true) {
                  setError("屏幕录制已授权,但麦克风未授权。请到 系统设置→隐私与安全性→麦克风 勾选 ScreenRecordHost,再点一次「开始录制」。");
                } else if (chkCamera.checked && perm.camera !== true) {
                  setError("屏幕录制与麦克风已授权,但摄像头未授权。请到 系统设置→隐私与安全性→摄像头 勾选 ScreenRecordHost,再点一次「开始录制」。");
                } else {
                  // 权限都正常但仍失败:必须带上原始错误(宿主日志见
                  // ~/Library/Logs/ScreenRecordHost.log),否则无法定位
                  setError(
                    "权限均已授权,但录制启动失败。原始错误:\n" + String(e) +
                    "\n\n可把 ~/Library/Logs/ScreenRecordHost.log 的内容发给维护者。"
                  );
                }
              } else {
                setError(permissionGuide(String(e)));
              }
            })
            .catch(() => setError(permissionGuide(String(e))));
        });
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
