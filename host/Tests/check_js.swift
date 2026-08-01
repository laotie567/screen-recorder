// JS 语法/冒烟检查:用 JavaScriptCore 评估扩展脚本(chrome API 以 stub 注入)。
// 用法:swift check_js.swift <js文件> [<js文件>...]
import Foundation
import JavaScriptCore

// 最小 chrome API + DOM stub(覆盖 service-worker 与 popup/批注页脚本)
let stub = """
var chrome = {
  runtime: {
    connectNative: function () {
      return {
        onMessage: { addListener: function () {} },
        onDisconnect: { addListener: function () {} },
        postMessage: function () {}
      };
    },
    sendMessage: function () { return Promise.resolve(); },
    onMessage: { addListener: function () {} },
    getURL: function (p) { return p; },
    lastError: null
  },
  tabs: { create: function () {} }
};
function __makeCtx() {
  return {
    clearRect: function () {}, drawImage: function () {}, strokeRect: function () {},
    beginPath: function () {}, moveTo: function () {}, lineTo: function () {},
    stroke: function () {}, fill: function () {}, save: function () {}, restore: function () {},
    arc: function () {}, fillText: function () {}, putImageData: function () {},
    getImageData: function () { return { data: [] }; }, filter: "", lineWidth: 0,
    strokeStyle: "", fillStyle: "", lineCap: "", lineJoin: "", font: "", textBaseline: "",
    globalCompositeOperation: ""
  };
}
function __makeEl() {
  return {
    textContent: "", innerHTML: "", title: "", disabled: false,
    className: "", style: {}, value: "", src: "", width: 0, height: 0,
    parentElement: { insertBefore: function () {} }, nextSibling: null,
    getContext: function () { return __makeCtx(); },
    getBoundingClientRect: function () { return { left: 0, top: 0, width: 0, height: 0 }; },
    setPointerCapture: function () {},
    classList: { toggle: function () {}, add: function () {}, remove: function () {} },
    addEventListener: function () {}, append: function () {}, appendChild: function () {}
  };
}
var document = {
  getElementById: function () { return __makeEl(); },
  createElement: function () { return __makeEl(); },
  querySelectorAll: function () { return []; }
};
var window = { close: function () {} };
var navigator = { clipboard: { write: function () { return Promise.resolve(); } } };
var ClipboardItem = function () {};
var URL = { createObjectURL: function () { return ""; }, revokeObjectURL: function () {} };
"""

var failed = false
for path in CommandLine.arguments.dropFirst() {
    guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("FAIL: cannot read \(path)")
        failed = true
        continue
    }
    let ctx = JSContext()!
    ctx.exceptionHandler = { _, exc in
        if let exc {
            print("FAIL \(path): \(exc)")
            failed = true
        }
    }
    ctx.evaluateScript(stub)
    ctx.evaluateScript(src)
    if ctx.exception == nil {
        print("PASS: \(path) (\(src.count) bytes)")
    } else {
        failed = true
    }
}
exit(failed ? 1 : 0)
