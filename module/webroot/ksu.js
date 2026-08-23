/*
 * ksu.js — KernelSU WebUI 桥接（kernelsu npm 库的最小自包含实现）
 * 依赖 KernelSU 管理器 WebView 注入的 window.ksu 对象；
 * 在普通浏览器中打开时 ksuApi.available 为 false，页面会显示提示。
 *
 * 修复记录（260823 审查后）：
 * - available 同时校验 exec 与 spawn，避免 spawn 缺失导致静默卡死
 * - spawn 同步抛错改为异步 emit，保证监听器挂载后再触发
 * - 回调名追加随机后缀，降低被同上下文脚本预测/劫持的风险
 * - exec 增加 60s 超时兜底，回调永不返回时 reject 并清理 window[cb]
 * - Stdio/ChildProcess 的 emit 快照监听列表并做异常隔离，单个监听抛错不中断后续
 * - errno 统一归一为数字，避免字符串 "0" 被误判为失败
 */
(function () {
  'use strict';

  var ksu = window.ksu;
  var available = !!(ksu && typeof ksu.exec === 'function' && typeof ksu.spawn === 'function');
  var counter = 0;
  var EXEC_TIMEOUT_MS = 60000;

  function uniq(prefix) {
    var rand = Math.random().toString(36).slice(2, 10);
    return prefix + '_cb_' + Date.now().toString(36) + '_' + rand + '_' + (counter++);
  }

  /* 执行一条 root 命令，返回 Promise<{errno, stdout, stderr}> */
  function exec(command, options) {
    options = options || {};
    return new Promise(function (resolve, reject) {
      if (!available) {
        reject(new Error('KernelSU 桥不可用'));
        return;
      }
      var cb = uniq('exec');
      var timer = null;
      var done = false;

      function finish(err, res) {
        if (done) return;
        done = true;
        if (timer) clearTimeout(timer);
        delete window[cb];
        if (err) reject(err);
        else resolve(res);
      }

      window[cb] = function (errno, stdout, stderr) {
        finish(null, { errno: Number(errno) || 0, stdout: stdout || '', stderr: stderr || '' });
      };
      timer = setTimeout(function () {
        finish(new Error('执行超时: ' + command));
      }, EXEC_TIMEOUT_MS);
      try {
        ksu.exec(command, JSON.stringify(options), cb);
      } catch (e) {
        finish(e);
      }
    });
  }

  /* 事件流容器（与 kernelsu 包保持一致） */
  function Stdio() {
    this.listeners = {};
  }
  Stdio.prototype.on = function (event, listener) {
    (this.listeners[event] = this.listeners[event] || []).push(listener);
    return this;
  };
  Stdio.prototype.emit = function (event) {
    var list = (this.listeners[event] || []).slice();
    var args = Array.prototype.slice.call(arguments, 1);
    for (var i = 0; i < list.length; i++) {
      try {
        list[i].apply(null, args);
      } catch (e) {
        /* 单个监听抛错不中断后续监听 */
      }
    }
  };

  function ChildProcess() {
    this.listeners = {};
    this.stdin = new Stdio();
    this.stdout = new Stdio();
    this.stderr = new Stdio();
  }
  ChildProcess.prototype.on = function (event, listener) {
    (this.listeners[event] = this.listeners[event] || []).push(listener);
    return this;
  };
  ChildProcess.prototype.emit = function (event) {
    var list = (this.listeners[event] || []).slice();
    var args = Array.prototype.slice.call(arguments, 1);
    for (var i = 0; i < list.length; i++) {
      try {
        list[i].apply(null, args);
      } catch (e) {
        /* 同上 */
      }
    }
  };

  /* 启动一条 root 命令并流式返回 stdout/stderr */
  function spawn(command, args, options) {
    if (args && !(args instanceof Array)) {
      options = args;
      args = [];
    }
    args = args || [];
    options = options || {};

    var child = new ChildProcess();
    if (!available) {
      setTimeout(function () { child.emit('error', new Error('KernelSU 桥不可用')); }, 0);
      return child;
    }
    var cb = uniq('spawn');
    window[cb] = child;
    child.on('exit', function () { delete window[cb]; });
    try {
      ksu.spawn(command, JSON.stringify(args), JSON.stringify(options), cb);
    } catch (e) {
      delete window[cb];
      setTimeout(function () { child.emit('error', e); }, 0);
    }
    return child;
  }

  function toast(message) {
    if (ksu && typeof ksu.toast === 'function') ksu.toast(message);
  }

  function moduleInfo() {
    if (ksu && typeof ksu.moduleInfo === 'function') return ksu.moduleInfo();
    return '';
  }

  window.ksuApi = {
    exec: exec,
    spawn: spawn,
    toast: toast,
    moduleInfo: moduleInfo,
    available: available
  };
})();
