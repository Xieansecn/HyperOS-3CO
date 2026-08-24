(function () {
  'use strict';

  var api = window.ksuApi;

  /* ---------- 常量 ---------- */
  var FALLBACK_MOD_ID = 'HyperOS-3CO';
  var MOD_DIR = '/data/adb/modules/' + FALLBACK_MOD_ID;
  var AUTO_REFRESH_MS = 60000;
  var REFRESH_DELAY_MS = 500;
  var SPAWN_TIMEOUT_MS = 90000;
  var LOG_MAX_NODES = 1600;

  /* 8 个开关 + 定时窗口，与 action.sh CONFIG_KEYS / check_status.sh 输出对应 */
  var TOGGLE_DEFS = {
    enable_battery_sync: {
      label: '电池白名单同步',
      desc: '把 deviceidle 电池白名单同步到 PowerKeeper / Joyose',
      def: '1'
    },
    enable_static_protect: {
      label: 'PowerKeeper 静态保护',
      desc: '把所有第三方应用写入 noRestrict + 多白名单',
      def: '0',
      hot: true
    },
    enable_refresh_follow: {
      label: '高刷跟随系统',
      desc: '清除云控 FPS 名单，高刷跟随系统刷新率设置',
      def: '1'
    },
    enable_perf_thermal: {
      label: '性能热控调优',
      desc: '停止热控服务，可能影响充电 / 温控',
      def: '0',
      hot: true
    },
    gpu_boost: {
      label: '禁用 GPU Boost（高通）',
      desc: 'service.sh 启动时锁定 GPU 节点',
      def: 'false'
    },
    enable_screen_off_freeze: {
      label: '息屏冻结（省电）',
      desc: '开机把非豁免三方应用切为可冻结态，息屏后被冻结/清理；豁免=deviceidle 白名单+白名单文件',
      def: '0',
      hot: true
    },
    enable_kernel_freeze: {
      label: '内核级冻结（实验）',
      desc: '写入 FrozenControlStatus 启用进程冻结（息屏 ~60s 冻结、唤醒秒解冻）；依赖系统冻结器',
      def: '0',
      hot: true
    },
    enable_nightly_freeze: {
      label: '夜间定时息屏冻结',
      desc: '窗口内自动冻结、窗口外自动恢复；需开启「息屏冻结（省电）」配合',
      def: '0',
      hot: true
    }
  };

  /* 与 action.sh 交互菜单 1-8 一一对应（数字即菜单编号） */
  var ACTION_DEFS = [
    { id: 1, label: '覆盖 Joyose 云控', cmd: 'joyose' },
    { id: 2, label: '同步电池优化白名单', cmd: 'sync_battery' },
    { id: 3, label: 'PowerKeeper 静态保护', cmd: 'powerkeeper', confirm: true },
    { id: 4, label: '高刷跟随系统刷新率', cmd: 'refresh' },
    { id: 5, label: '查看当前云控状态', cmd: 'status' },
    { id: 6, label: '重启 PowerKeeper', cmd: 'restart_pk' },
    { id: 7, label: '备份云控数据库', cmd: 'backup' },
    { id: 8, label: '恢复充电', cmd: 'restore_charging', confirm: true, danger: true },
    { id: 9, label: '息屏冻结（立即）', cmd: 'freeze', confirm: true },
    { id: 10, label: '即时恢复', cmd: 'unfreeze', confirm: true, danger: true },
    { id: 11, label: '一键还原（清理式），让云控重拉', cmd: 'reset', confirm: true, danger: true }
  ];

  var state = {
    flags: {},
    refreshing: false
  };

  var refreshSeq = 0;
  var logBuffer = '';
  var destroyed = false;
  var autoTimer = null;

  /* ---------- 工具 ---------- */
  function $(id) { return document.getElementById(id); }

  /* moduleInfo() 返回模块信息 JSON（字符串或对象），解析出模块目录 */
  function getModuleInfo() {
    try {
      var raw = api.moduleInfo();
      if (!raw) return null;
      return (typeof raw === 'string') ? JSON.parse(raw) : raw;
    } catch (e) {
      return null;
    }
  }

  /* 模块目录白名单校验：仅接受标准形态，杜绝路径/命令注入面 */
  function resolveModuleDir() {
    var info = getModuleInfo();
    var dir = '';
    if (info && info.moduleDir) dir = info.moduleDir;
    else if (info && info.id) dir = '/data/adb/modules/' + info.id;
    if (/^\/data\/adb\/modules\/[A-Za-z0-9_.-]+$/.test(dir)) return dir;
    return '/data/adb/modules/' + FALLBACK_MOD_ID;
  }

  function stripAnsi(s) {
    return String(s).replace(/\x1b\[[0-9;]*m/g, '');
  }

  var logBox = null;
  function ensureLog() {
    if (!logBox) logBox = $('log');
    return logBox;
  }

  function log(text, cls) {
    var box = ensureLog();
    if (!box) return;
    if (box.querySelector('.log-empty')) box.innerHTML = '';
    /* 仅当用户已贴近底部时才自动跟随，避免回看历史日志被拽到最末行 */
    var nearBottom = (box.scrollHeight - box.scrollTop - box.clientHeight) < 48;
    var div = document.createElement('div');
    div.className = 'log-line' + (cls ? ' ' + cls : '');
    var now = new Date();
    function p2(n) { return (n < 10 ? '0' : '') + n; }
    div.textContent = '[' + p2(now.getHours()) + ':' + p2(now.getMinutes()) + ':' + p2(now.getSeconds()) + '] ' + stripAnsi(text);
    box.appendChild(div);
    while (box.childElementCount > LOG_MAX_NODES) box.removeChild(box.firstChild);
    if (nearBottom) box.scrollTop = box.scrollHeight;
  }

  function logLine(text) { log(text, 'dim'); }
  function logOk(text) { log(text, 'ok'); }
  function logErr(text) { log(text, 'danger'); }
  function logWarn(text) { log(text, 'warn'); }
  function logSep() { log('', ''); }

  function clearLog() {
    var box = ensureLog();
    if (!box) return;
    box.innerHTML = '<div class="log-empty">暂无输出，点击上方操作查看实时日志。</div>';
  }

  /* 全局执行中指示：计数式，end 并发执行(重启/白名单/动作)不会互相清除；
     busy 递增，'' 递减到 0 才隐藏顶栏/日志页 spinner */
  var busyCount = 0;
  function setRunStatus(mode) {
    if (mode === 'busy') busyCount++;
    else if (mode === '') busyCount = busyCount > 0 ? busyCount - 1 : 0;
    var active = busyCount > 0;
    var hdr = document.querySelector('header');
    if (hdr) hdr.classList.toggle('busy', active);
    var el = $('run-status');
    if (!el) return;
    el.textContent = '';
    if (active) {
      var sp = document.createElement('span');
      sp.className = 'spinner';
      el.appendChild(sp);
      el.appendChild(document.createTextNode('执行中…'));
    }
  }

  function toast(msg) { if (api) api.toast(msg); }

  /* ---------- 页内确认对话框（替代原生 confirm：不阻塞 JS 线程，兼容 KsuWebUIStandalone 等不支持 JS 对话框的实现） ---------- */
  var dlgQueue = [];
  var dlgActive = false;
  var dlgCurrent = null;

  function uiConfirm(text, opts) {
    opts = opts || {};
    return new Promise(function (resolve) {
      dlgQueue.push({ text: text, opts: opts, resolve: resolve });
      pumpConfirm();
    });
  }

  function pumpConfirm() {
    if (dlgActive || !dlgQueue.length) return;
    dlgActive = true;
    var req = dlgQueue.shift();
    var overlay = $('confirm-dlg');
    if (!overlay) { dlgActive = false; req.resolve(false); pumpConfirm(); return; }
    dlgCurrent = req;
    $('dlg-text').textContent = req.text;
    var okBtn = $('dlg-ok');
    if (okBtn) {
      okBtn.textContent = req.opts.okText || '确定';
      okBtn.classList.toggle('danger', !!req.opts.danger);
    }
    overlay.classList.add('show');
  }

  function settleConfirm(result) {
    if (!dlgCurrent) return;
    var req = dlgCurrent;
    dlgCurrent = null;
    var overlay = $('confirm-dlg');
    if (overlay) overlay.classList.remove('show');
    dlgActive = false;
    req.resolve(result);
    pumpConfirm();
  }

  /* 所有后端命令统一经 scripts/api.sh 分发（非阻塞入口），不直接拼系统命令 */
  function shCmd(cmd) { return 'sh ' + MOD_DIR + '/scripts/api.sh ' + cmd; }

  /* ---------- Tab 切换 ---------- */
  function switchTab(name) {
    document.querySelectorAll('#pages .page').forEach(function (p) {
      p.classList.toggle('active', p.id === 'tab-' + name);
    });
    document.querySelectorAll('#tabbar .tab-btn').forEach(function (b) {
      b.classList.toggle('active', b.dataset.tab === name);
    });
    var fab = $('fab-group');
    if (fab) fab.classList.toggle('show', name === 'logs');
  }

  /* ---------- 状态解析 ---------- */
  function parseStatus(text) {
    var out = { flags: {}, nightly: null, freezeStart: null, freezeEnd: null, battery: null, joyose: null, noRestrict: null, hr: null, deviceidle: null, backup: null, freezeState: null };
    var lines = String(text).split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var m;
      /* 通用 key=value 捕获：除 name/version 等已知非开关行外全部存入 flags，
         新增开关/定时字段无需再同步白名单；gpu_boost 未设置时归一为 false，
         freeze_* 三行同时映射到 out 供定时窗口使用 */
      if ((m = line.match(/^\s*([a-z_]+)\s*=\s*(\S+)/)) && m[1] !== 'name' && m[1] !== 'version') {
        var v = (m[2] === '(未设置/默认)') ? 'false' : m[2];
        out.flags[m[1]] = v;
        if (m[1] === 'enable_nightly_freeze') {
          out.nightly = v;
        } else if (m[1] === 'freeze_start_time') {
          out.freezeStart = v;
          out.flags.freezeStart = v;
        } else if (m[1] === 'freeze_end_time') {
          out.freezeEnd = v;
          out.flags.freezeEnd = v;
        }
      } else if ((m = line.match(/background_freeze_whitelist 数量:\s*(\d+)/))) {
        out.joyose = m[1];
      } else if ((m = line.match(/userTable noRestrict 数量:\s*(\d+)/))) {
        out.noRestrict = m[1];
      } else if ((m = line.match(/highRefreshRateTable 数量:\s*(\d+)/))) {
        out.hr = m[1];
      } else if ((m = line.match(/deviceidle user 白名单数量:\s*(\d+)/))) {
        out.deviceidle = m[1];
      } else if ((m = line.match(/battery: status=(.+?) capacity=(\S+)% temp=(\S+) current=(\S+)uA voltage=(\S+)uV/))) {
        out.battery = { status: m[1].trim(), capacity: m[2], temp: m[3], current: m[4], voltage: m[5] };
      } else if ((m = line.match(/^\s*状态: (\S+)/))) {
        out.freezeState = m[1];
      } else if ((m = line.match(/^(cloud_configure|user_configure|joyose_teg|highrefreshrate)_\d{8}-\d{6}_/))) {
        out.backup = (parseInt(out.backup || '0', 10) + 1).toString();
      }
    }
    return out;
  }

  function renderOverview(s) {
    var batt = $('s-battery');
    if (batt) {
      if (s.battery) {
        var t = parseInt(s.battery.temp, 10);
        var cap = parseInt(s.battery.capacity, 10);
        if (isNaN(t)) t = 0;
        if (isNaN(cap)) cap = 0;
        var cls = '';
        if (t >= 400) cls = ' warn';
        if (cap <= 15) cls = ' danger';
        batt.className = 'hero-value' + cls;
        batt.textContent =
          s.battery.status + ' · ' + s.battery.capacity + '% · ' +
          (t / 10).toFixed(1) + '°C';
        batt.title = '电流 ' + s.battery.current + 'uA · 电压 ' + s.battery.voltage + 'uV';
      } else {
        batt.className = 'hero-value';
        batt.textContent = '—';
        batt.title = '';
      }
    }
    setStat('s-joyose', s.joyose);
    setStat('s-norestrict', s.noRestrict);
    setStat('s-hr', s.hr);
    setStat('s-deviceidle', s.deviceidle);
    setStat('s-backup', s.backup);
    setStat('s-freeze', s.freezeState === 'applied' ? '开' : (s.freezeState === 'restored' ? '关' : '-'));
    var t2 = $('overview-time');
    if (t2) t2.textContent = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  }

  function setStat(id, val) {
    var el = $(id);
    if (!el) return;
    el.className = 'metric-value';
    el.textContent = (val == null || val === '') ? '—' : val;
  }

  /* ---------- 开关 ---------- */
  var lastToggleSig = '';
  function renderToggles(flags) {
    var wrap = $('toggles');
    if (!wrap) return;
    /* 开关区签名：状态未变时跳过重建，避免自动刷新打断交互/闪烁；pending 写入的开关也能保持禁用态 */
    var sig = Object.keys(TOGGLE_DEFS).map(function (k) {
      return k + '=' + (flags[k] != null ? flags[k] : TOGGLE_DEFS[k].def);
    }).join('&') + '|' + (flags.freezeStart || flags.freeze_start_time || '') + '|' + (flags.freezeEnd || flags.freeze_end_time || '');
    if (sig === lastToggleSig && wrap.childElementCount > 0) {
      Object.keys(TOGGLE_DEFS).forEach(function (key) {
        state.flags[key] = flags[key] != null ? flags[key] : TOGGLE_DEFS[key].def;
      });
      return;
    }
    /* 用户正在时间输入框聚焦编辑时，即使状态变化也先不重建，避免输入被打断；失焦后下次刷新再收敛 */
    var ae = document.activeElement;
    if (ae && wrap.contains(ae) && ae.className === 'time-input') {
      Object.keys(TOGGLE_DEFS).forEach(function (key) {
        state.flags[key] = flags[key] != null ? flags[key] : TOGGLE_DEFS[key].def;
      });
      return;
    }
    lastToggleSig = sig;
    wrap.innerHTML = '';
    Object.keys(TOGGLE_DEFS).forEach(function (key) {
      var def = TOGGLE_DEFS[key];
      var val = flags[key] != null ? flags[key] : def.def;
      state.flags[key] = val;

      var row = document.createElement('div');
      row.className = 'toggle-row';

      var txt = document.createElement('div');
      txt.className = 'txt';
      var name = document.createElement('div');
      name.className = 't-name';
      name.textContent = def.label;
      if (def.hot) {
        var tag = document.createElement('span');
        tag.className = 'tag hot';
        tag.textContent = '风险';
        name.appendChild(tag);
      }
      var desc = document.createElement('div');
      desc.className = 't-desc';
      desc.textContent = def.desc;
      txt.appendChild(name);
      txt.appendChild(desc);

      var sw = document.createElement('label');
      sw.className = 'switch';
      var input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = (val === '1' || val === 'true');
      input.addEventListener('change', function () {
        setToggle(key, input.checked, input);
      });
      var track = document.createElement('span');
      track.className = 'track';
      var thumb = document.createElement('span');
      thumb.className = 'thumb';
      sw.appendChild(input);
      sw.appendChild(track);
      sw.appendChild(thumb);

      row.appendChild(txt);
      row.appendChild(sw);
      wrap.appendChild(row);
    });

    /* 定时窗口行：窗口内自动冻结、窗口外自动恢复 */
    var start = normTime(flags.freezeStart || flags.freeze_start_time, '23:00');
    var end = normTime(flags.freezeEnd || flags.freeze_end_time, '07:00');

    var row = document.createElement('div');
    row.className = 'toggle-row';
    var txt = document.createElement('div');
    txt.className = 'txt';
    var name = document.createElement('div');
    name.className = 't-name';
    name.textContent = '定时窗口';
    var desc = document.createElement('div');
    desc.className = 't-desc';
    desc.textContent = '窗口内自动冻结、窗口外自动恢复；需开启「夜间定时息屏冻结」配合';
    txt.appendChild(name);
    txt.appendChild(desc);

    var timeWrap = document.createElement('div');
    timeWrap.className = 'time-wrap';
    var tStart = document.createElement('input');
    tStart.type = 'time';
    tStart.className = 'time-input';
    tStart.value = start;
    tStart.addEventListener('change', function () { setTimeWindow('freeze_start_time', tStart.value, tStart); });
    var dash = document.createElement('span');
    dash.className = 'time-dash';
    dash.textContent = '–';
    var tEnd = document.createElement('input');
    tEnd.type = 'time';
    tEnd.className = 'time-input';
    tEnd.value = end;
    tEnd.addEventListener('change', function () { setTimeWindow('freeze_end_time', tEnd.value, tEnd); });
    timeWrap.appendChild(tStart);
    timeWrap.appendChild(dash);
    timeWrap.appendChild(tEnd);

    row.appendChild(txt);
    row.appendChild(timeWrap);
    wrap.appendChild(row);
  }

  function normTime(v, def) {
    return (/^\d{2}:\d{2}$/.test(v)) ? v : def;
  }

  function setTimeWindow(key, value, input) {
    if (!/^\d{2}:\d{2}$/.test(value)) {
      logErr('非法时间值，已拒绝: ' + value);
      return;
    }
    input.disabled = true;
    logWarn('[config] 设置 ' + key + '=' + value);
    api.exec(shCmd('config_set ' + key + ' ' + value))
      .then(function (res) {
        if (destroyed) return;
        if (input.isConnected) input.disabled = false;
        if (res.errno !== 0) {
          logErr(res.stderr || ('config_set 失败 (errno=' + res.errno + ')'));
          toast('设置失败');
          return;
        }
        state.flags[key] = value;
        if (res.stdout) logLine(res.stdout.trim());
        toast(key + ' = ' + value);
        setTimeout(refreshStatus, REFRESH_DELAY_MS);
      })
      .catch(function (e) {
        if (destroyed) return;
        if (input.isConnected) input.disabled = false;
        logErr('config_set 异常: ' + ((e && e.message) || e));
      });
  }

  function setToggle(key, checked, input) {
    var def = TOGGLE_DEFS[key];
    var newVal = (def.def === 'true' || def.def === 'false') ? (checked ? 'true' : 'false') : (checked ? '1' : '0');

    if (def.hot && checked) {
      uiConfirm('开启「' + def.label + '」可能影响充电/温控，确认继续？', { okText: '开启', danger: true }).then(function (ok) {
        if (!ok) { if (input.isConnected) input.checked = false; return; }
        applyToggle(key, checked, input, newVal);
      });
      return;
    }
    applyToggle(key, checked, input, newVal);
  }

  function applyToggle(key, checked, input, newVal) {
    input.disabled = true;
    logWarn('[config] 设置 ' + key + '=' + newVal);
    api.exec(shCmd('config_set ' + key + ' ' + newVal))
      .then(function (res) {
        if (destroyed) return;
        if (res.errno !== 0) {
          logErr(res.stderr || ('config_set 失败 (errno=' + res.errno + ')'));
          if (input.isConnected) {
            input.disabled = false;
            input.checked = !checked;
          }
          toast('设置失败');
          return;
        }
        state.flags[key] = newVal;
        if (input.isConnected) input.disabled = false;
        if (res.stdout) logLine(res.stdout.trim());
        toast(key + ' = ' + newVal);
        setTimeout(refreshStatus, REFRESH_DELAY_MS);
      })
      .catch(function (e) {
        if (destroyed) return;
        if (input.isConnected) {
          input.disabled = false;
          input.checked = !checked;
        }
        logErr('config_set 异常: ' + ((e && e.message) || e));
      });
  }

  /* ---------- 快捷操作 ---------- */
  function renderActions() {
    var wrap = $('actions');
    if (!wrap) return;
    wrap.innerHTML = '';
    ACTION_DEFS.forEach(function (a) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn' + (a.danger ? ' danger' : '');
      btn.dataset.cmd = a.cmd;
      btn.dataset.confirm = a.confirm ? '1' : '0';
      var num = document.createElement('span');
      num.className = 'b-num';
      num.textContent = a.id;
      btn.appendChild(num);
      btn.appendChild(document.createTextNode(a.label));
      btn.addEventListener('click', function () { runAction(btn); });
      wrap.appendChild(btn);
    });
  }

  function runAction(btn) {
    if (btn.disabled) return;
    if (btn.dataset.confirm === '1') {
      var label = btn.textContent.replace(/^\d+/, '').trim();
      uiConfirm('确认执行「' + label + '」？', { okText: '执行', danger: btn.classList.contains('danger') }).then(function (ok) {
        if (ok) runActionExec(btn);
      });
      return;
    }
    runActionExec(btn);
  }

  function runActionExec(btn) {
    if (btn.disabled) return;
    btn.disabled = true;
    btn.classList.add('busy');
    setRunStatus('busy');
    logSep();
    logWarn('$ ' + shCmd(btn.dataset.cmd));

    var settled = false;
    var watchdog = null;
    function settle(ok) {
      if (settled) return;
      settled = true;
      if (watchdog) clearTimeout(watchdog);
      flushLog();
      btn.disabled = false;
      btn.classList.remove('busy');
      setRunStatus('');
      if (ok) {
        logOk('完成 ✓');
        toast('执行完成');
        setTimeout(refreshStatus, REFRESH_DELAY_MS);
        setTimeout(refreshBackups, REFRESH_DELAY_MS);
      } else {
        logErr('执行失败 ✗');
        toast('执行失败');
      }
    }

    var child = api.spawn('sh', [MOD_DIR + '/scripts/api.sh', btn.dataset.cmd]);
    watchdog = setTimeout(function () {
      if (!settled) {
        logErr('前端等待超时（' + Math.round(SPAWN_TIMEOUT_MS / 1000) + 's）；后端进程可能仍在运行，最终结果请以日志/状态页为准');
        settle(false);
      }
    }, SPAWN_TIMEOUT_MS);

    child.stdout.on('data', function (chunk) { chunkToLog(chunk, false); });
    child.stderr.on('data', function (chunk) { chunkToLog(chunk, true); });
    child.on('error', function (e) {
      logErr('执行失败: ' + ((e && e.message) || e));
      settle(false);
    });
    child.on('exit', function (code) {
      settle(code === 0);
    });
  }

  /* 跨 chunk 行缓冲：chunk 边界不截断半行 */
  function chunkToLog(chunk, isErr) {
    logBuffer += String(chunk).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    var lines = logBuffer.split('\n');
    logBuffer = lines.pop();
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\r$/, '');
      if (line.trim() !== '') log(line, isErr ? 'warn' : '');
    }
  }

  function flushLog() {
    var rest = logBuffer.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    logBuffer = '';
    if (rest.trim() !== '') log(rest, '');
  }

  /* ---------- 状态刷新 ---------- */
  function refreshStatus() {
    if (destroyed || state.refreshing) return;
    state.refreshing = true;
    var seq = ++refreshSeq;
    var btn = $('btn-refresh-status');
    if (btn) btn.disabled = true;
    var t0 = Date.now();
    function resetUi() {
      if (destroyed || seq !== refreshSeq) return;
      state.refreshing = false;
      var b2 = $('btn-refresh-status');
      if (b2) b2.disabled = false;
      clearStatusSkeleton();
    }
    api.exec(shCmd('status'))
      .then(function (res) {
        if (destroyed || seq !== refreshSeq) return;
        if (res.errno !== 0) {
          logErr(res.stderr || ('自检失败 errno=' + res.errno));
          renderToggles(state.flags);
          var t2 = $('overview-time');
          if (t2) t2.textContent = '刷新失败 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
          toast('自检失败');
          return;
        }
        var s = parseStatus(res.stdout);
        state.flags = s.flags;
        renderOverview(s);
        renderToggles(s.flags);
        logLine('[status] 刷新完成（' + ((Date.now() - t0) / 1000).toFixed(1) + 's）');
      })
      .catch(function (e) {
        if (destroyed || seq !== refreshSeq) return;
        renderToggles(state.flags);
        logErr('自检异常: ' + ((e && e.message) || e));
      })
      .then(resetUi, resetUi);
  }

  /* 状态数据未就绪时清掉骨架屏占位，避免停留在 shimmer */
  function clearStatusSkeleton() {
    ['s-battery', 's-joyose', 's-norestrict', 's-hr', 's-deviceidle', 's-backup', 's-freeze'].forEach(function (id) {
      var el = $(id);
      if (el && el.querySelector('.skeleton')) el.textContent = '—';
    });
  }

  /* ---------- 备份管理 ---------- */
  function fmtSize(n) {
    if (n >= 1048576) return (n / 1048576).toFixed(1) + 'MB';
    if (n >= 1024) return (n / 1024).toFixed(1) + 'KB';
    return n + 'B';
  }

  function refreshBackups() {
    var listEl = $('backup-list');
    var sumEl = $('backup-summary');
    if (!listEl || !sumEl) return;
    api.exec(shCmd('backup_list'))
      .then(function (res) {
        if (destroyed) return;
        var files = [];
        String(res.stdout).split('\n').forEach(function (line) {
          var m = line.match(/^(.+?)\t(\d+)$/);
          if (m) files.push({ name: m[1], size: parseInt(m[2], 10) });
        });
        sumEl.textContent = files.length ? files.length + ' 份' : '';
        listEl.innerHTML = '';
        if (!files.length) {
          listEl.innerHTML = '<span class="log-empty">暂无备份</span>';
          return;
        }
        files.forEach(function (f) {
          var row = document.createElement('div');
          row.className = 'backup-item';
          var name = document.createElement('span');
          name.className = 'b-name';
          name.textContent = f.name;
          name.title = f.name;
          var size = document.createElement('span');
          size.className = 'b-size';
          size.textContent = fmtSize(f.size);
          var del = document.createElement('button');
          del.type = 'button';
          del.className = 'b-del';
          del.title = '删除备份';
          del.setAttribute('aria-label', '删除备份');
          del.innerHTML = '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>';
          del.addEventListener('click', function () { deleteBackup(f.name, del); });
          row.appendChild(name);
          row.appendChild(size);
          row.appendChild(del);
          listEl.appendChild(row);
        });
      })
      .catch(function (e) {
        if (destroyed) return;
        listEl.innerHTML = '<span class="log-empty">读取备份失败</span>';
        logErr('备份列表异常: ' + ((e && e.message) || e));
      });
  }

  function deleteBackup(name, delBtn) {
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) {
      logErr('非法备份文件名，已拒绝: ' + name);
      return;
    }
    uiConfirm('确认删除备份 ' + name + ' ？', { okText: '删除', danger: true }).then(function (ok) {
      if (!ok) return;
      delBtn.disabled = true;
      api.exec(shCmd('backup_delete ' + name))
      .then(function (res) {
        if (destroyed) return;
        delBtn.disabled = false;
        if (res.errno !== 0) {
          logErr(res.stderr || '删除失败');
          toast('删除失败');
          return;
        }
        if (res.stdout) logLine(res.stdout.trim());
        toast('已删除');
        refreshBackups();
        setTimeout(refreshStatus, REFRESH_DELAY_MS);
      })
      .catch(function (e) {
        if (destroyed) return;
        delBtn.disabled = false;
        logErr('删除异常: ' + ((e && e.message) || e));
      });
    });
  }

  /* ---------- 系统白名单（云控，可编辑） ---------- */
  var WLS_DEFS = [
    { name: 'FrozenNewWhiteList', label: '冻结豁免', desc: '息屏冻结/清理不动的应用（含 QQ/微信/音乐等）。息屏冻结启用时，非豁免三方会从这里移除以便冻结' },
    { name: 'dozeWhiteListApps', label: 'Doze 豁免', desc: '系统深度休眠期间仍可联网/被唤醒的应用（含小米推送通道）。电池白名单同步会追加 deviceidle 白名单' },
    { name: 'levelUtimateSpecialApps', label: '终极保护', desc: '系统最高保活等级（核心通讯）。不会被后台清理/杀进程；息屏冻结策略下仍可冻结' },
    { name: 'sleep_mode_network_white_apps', label: '睡眠网络', desc: '夜间睡眠窗口内仍允许联网的系统组件（xmsf/securitycore/networkstack 等），保证推送可达' }
  ];
  var currentWls = null;

  function isValidPkg(pkg) {
    return /^[A-Za-z0-9_.]+$/.test(pkg) &&
      pkg.charAt(0) !== '.' && pkg.slice(-1) !== '.' && pkg.indexOf('..') < 0;
  }

  function renderWlsTabs() {
    var wrap = $('wls-tabs');
    if (!wrap) return;
    wrap.innerHTML = '';
    WLS_DEFS.forEach(function (d) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'wls-tab' + (currentWls === d.name ? ' active' : '');
      btn.textContent = d.label;
      btn.addEventListener('click', function () { switchWls(d.name); });
      wrap.appendChild(btn);
    });
  }

  function switchWls(name) {
    currentWls = name;
    wlsFilter = '';
    if (wlsDebounceTimer) { clearTimeout(wlsDebounceTimer); wlsDebounceTimer = null; }
    var si = $('wls-search');
    if (si) si.value = '';
    renderWlsTabs();
    var desc = $('wls-desc');
    if (desc) {
      var d = null;
      WLS_DEFS.forEach(function (x) { if (x.name === name) d = x; });
      if (d) {
        desc.textContent = d.label + '：' + d.desc;
      }
    }
    refreshWlsList();
  }

  var wlsPkgs = [];
  var wlsFilter = '';

  var wlsRenderToken = 0;
  var wlsSeq = 0;
  var wlsDebounceTimer = null;
  var WLS_RENDER_CHUNK = 80;
  function buildWlsRow(listName, pkg) {
    var row = document.createElement('div');
    row.className = 'wl-item';
    var nm = document.createElement('span');
    nm.className = 'wl-name';
    nm.textContent = pkg;
    nm.title = pkg;
    var del = document.createElement('button');
    del.type = 'button';
    del.className = 'wl-del';
    del.title = '移除';
    del.innerHTML = '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>';
    del.addEventListener('click', function () { removeWls(listName, pkg, del); });
    row.appendChild(nm);
    row.appendChild(del);
    return row;
  }

  /* 分块异步渲染：名单可能数百项，一次性全量重建会长时间阻塞主线程导致 WebUI 卡死。
     改为每批 WLS_RENDER_CHUNK 行、批间 setTimeout(0) 让出主线程；用自增 token 取消过期的渲染，
     快速切换名单/过滤/刷新时不会被上一次渲染覆盖也避免竞态。 */
  function renderWlsItems() {
    var listEl = $('wls-list');
    var sumEl = $('wls-summary');
    if (!listEl || !sumEl) return;
    var kw = wlsFilter.toLowerCase();
    var shown = kw ? wlsPkgs.filter(function (p) { return p.toLowerCase().indexOf(kw) >= 0; }) : wlsPkgs;
    sumEl.textContent = shown.length + ' / ' + wlsPkgs.length + ' 个';
    var renderName = currentWls; // 捕获本次渲染所属名单，供行绑定与 step 校验
    var token = ++wlsRenderToken;
    listEl.innerHTML = '';
    if (!shown.length) {
      listEl.innerHTML = '<div class="log-empty">' + (wlsPkgs.length ? '无匹配结果' : '名单为空') + '</div>';
      return;
    }
    var idx = 0;
    function step() {
      if (token !== wlsRenderToken) return; // 已被新的渲染取代（切换/刷新/过滤）
      if (renderName !== currentWls) return; // 名单已切换，作废本次渲染
      var end = Math.min(idx + WLS_RENDER_CHUNK, shown.length);
      var frag = document.createDocumentFragment();
      for (; idx < end; idx++) frag.appendChild(buildWlsRow(renderName, shown[idx]));
      if (frag.childElementCount) listEl.appendChild(frag);
      if (idx < shown.length) setTimeout(step, 0); // 让出主线程，长列表不阻塞 UI
    }
    step();
  }

  function refreshWlsList() {
    if (!currentWls) return;
    var reqName = currentWls;
    var seq = ++wlsSeq;
    wlsRenderToken++; // 作废未完成的旧渲染，防止上一名单的行残留
    var startList = $('wls-list');
    if (startList) startList.innerHTML = '<div class="log-empty">加载中…</div>';
    api.exec(shCmd('wl_sys_list ' + currentWls))
      .then(function (res) {
        if (destroyed || reqName !== currentWls || seq !== wlsSeq) return; // 忽略过期/已切换响应
        if (res.errno !== 0) {
          var errList = $('wls-list');
          if (errList) errList.innerHTML = '<div class="log-empty">读取失败（数据库缺失或忙），请稍后点右上角刷新重试</div>';
          if (res.stderr) logErr(res.stderr.trim());
          return;
        }
        wlsPkgs = [];
        String(res.stdout).split('\n').forEach(function (line) {
          var p = line.trim();
          if (p && isValidPkg(p)) wlsPkgs.push(p);
        });
        renderWlsItems();
      })
      .catch(function (e) {
        if (destroyed || seq !== wlsSeq) return;
        var listEl = $('wls-list');
        if (listEl) listEl.innerHTML = '<div class="log-empty">读取失败</div>';
        logErr('系统白名单异常: ' + ((e && e.message) || e));
      });
  }

  function wlsUpdateSummary() {
    var sumEl = $('wls-summary');
    if (!sumEl) return;
    var kw = wlsFilter.toLowerCase();
    var shown = kw ? wlsPkgs.filter(function (p) { return p.toLowerCase().indexOf(kw) >= 0; }).length : wlsPkgs.length;
    sumEl.textContent = shown + ' / ' + wlsPkgs.length + ' 个';
  }
  function wlsRowVisible(pkg) {
    var kw = wlsFilter.toLowerCase();
    return !kw || pkg.toLowerCase().indexOf(kw) >= 0;
  }
  function wlsInsertRow(listName, pkg) {
    var listEl = $('wls-list');
    if (!listEl) return;
    if (listEl.querySelector('.log-empty')) listEl.innerHTML = '';
    listEl.appendChild(buildWlsRow(listName, pkg));
  }
  function wlsShowPlaceholder() {
    var listEl = $('wls-list');
    if (!listEl) return;
    listEl.innerHTML = '<div class="log-empty">' + (wlsPkgs.length ? '无匹配结果' : '名单为空') + '</div>';
  }

  function addWls() {
    var input = $('wls-input');
    var addBtn = $('wls-add-btn');
    if (!input || !currentWls || input.disabled) return; // 防重入：正在写入时忽略重复触发
    var pkg = input.value.trim();
    var listName = currentWls; // 捕获发起时的名单，避免请求期间切换名单导致本地增量污染新名单
    if (!pkg) { toast('请输入包名'); return; }
    if (!isValidPkg(pkg)) { logErr('非法包名，已拒绝: ' + pkg); return; }
    input.disabled = true;
    if (addBtn) addBtn.disabled = true;
    setRunStatus('busy');
    logLine('[wl] 正在写入 ' + listName + '：' + pkg + '（若其它任务持锁需等待，最长约 45s）…');
    var addOk = false;
    api.exec(shCmd('wl_sys_add ' + listName + ' ' + pkg))
      .then(function (res) {
        if (destroyed) return;
        if (res.errno !== 0) {
          if (res.stdout) logLine(res.stdout.trim());
          logErr(res.stderr || ('添加失败 errno=' + res.errno));
          toast('添加失败');
          return;
        }
        addOk = true;
        if (res.stdout) logLine(res.stdout.trim());
        input.value = '';
        var already = res.stdout && res.stdout.indexOf('已在') >= 0;
        /* 仅当仍停留在原名单时才本地增量（避免切走污染新名单），
           且包尚未在数组里才 push/插行，防止重复行 */
        if (listName === currentWls && wlsPkgs.indexOf(pkg) < 0) {
          wlsPkgs.push(pkg);
          wlsUpdateSummary();
          if (wlsRowVisible(pkg)) wlsInsertRow(listName, pkg);
        }
        toast(already ? '已在名单中' : '已添加');
      })
      .catch(function (e) {
        if (destroyed) return;
        logErr('添加异常: ' + ((e && e.message) || e) + '（前端等待超时；后端可能已完成写入，正在重新读取名单）');
        toast('添加超时');
      })
      .then(function () {
        if (destroyed) return;
        if (input.isConnected) input.disabled = false;
        if (addBtn && addBtn.isConnected) addBtn.disabled = false;
        if (!addOk) refreshWlsList(); // 仅失败/超时才整表回读收敛（后端可能已改动）
        setRunStatus('');
      });
  }

  function wlsLabel(name) {
    for (var i = 0; i < WLS_DEFS.length; i++) if (WLS_DEFS[i].name === name) return WLS_DEFS[i].label;
    return name;
  }

  function removeWls(listName, pkg, delBtn) {
    if (delBtn.disabled) return; // 防重入
    uiConfirm('确认从「' + wlsLabel(listName) + '」移除 ' + pkg + ' ？\n移除后该应用可能被息屏冻结/后台清理。', { okText: '移除', danger: true })
      .then(function (ok) {
        if (!ok) return;
        delBtn.disabled = true;
        setRunStatus('busy');
        logLine('[wl] 正在从 ' + listName + ' 移除 ' + pkg + '…');
        var rmOk = false;
        api.exec(shCmd('wl_sys_remove ' + listName + ' ' + pkg))
          .then(function (res) {
            if (destroyed) return;
            if (res.errno !== 0) {
              if (res.stdout) logLine(res.stdout.trim());
              logErr(res.stderr || '移除失败');
              toast('移除失败');
              return;
            }
            rmOk = true;
            if (res.stdout) logLine(res.stdout.trim());
            /* 仅当仍停留在原名单时才本地增量（避免切走后污染当前名单/占位）；
               切换了名单则跳过本地更新，切回时会整表重读 */
            if (listName === currentWls) {
              var ix = wlsPkgs.indexOf(pkg);
              if (ix >= 0) wlsPkgs.splice(ix, 1);
              wlsUpdateSummary();
              var listEl = $('wls-list');
              if (listEl) {
                var rows = listEl.querySelectorAll('.wl-item');
                for (var i = 0; i < rows.length; i++) {
                  var nm = rows[i].querySelector('.wl-name');
                  if (nm && nm.textContent === pkg) { rows[i].parentNode.removeChild(rows[i]); break; }
                }
                if (!listEl.querySelector('.wl-item')) wlsShowPlaceholder();
              }
            }
            toast('已移除');
          })
          .catch(function (e) {
            if (destroyed) return;
            logErr('移除异常: ' + ((e && e.message) || e) + '（前端等待超时；后端可能已完成，正在重新读取名单）');
            toast('移除超时');
          })
          .then(function () {
            if (destroyed) return;
            if (delBtn.isConnected) delBtn.disabled = false;
            if (!rmOk) refreshWlsList(); // 仅失败/超时才整表回读收敛
            setRunStatus('');
          });
      });
  }

  /* ---------- 日志导出 ---------- */
  function collectLogText() {
    var box = ensureLog();
    if (!box) return '';
    var parts = [];
    box.querySelectorAll('.log-line').forEach(function (s) {
      if (s.classList.contains('log-empty')) return;
      parts.push(s.textContent);
    });
    return parts.join('\n');
  }

  function exportLog() {
    var text = collectLogText();
    if (!text) {
      toast('日志为空');
      return;
    }
    var btn = $('btn-export-log');
    if (!btn) return;
    btn.disabled = true;
    var now = new Date();
    function pad(n) { return (n < 10 ? '0' : '') + n; }
    var ts = '' + now.getFullYear() + pad(now.getMonth() + 1) + pad(now.getDate()) +
      '-' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds()) +
      '-' + Math.random().toString(36).slice(2, 6);
    var path = '/sdcard/Download/定制优化_日志_' + ts + '.txt';
    var delim = 'KSULOG_EOF_' + Math.random().toString(36).slice(2, 10);
    var cmd = "cat > '" + path + "' <<'" + delim + "'\n" + text + "\n" + delim;

    api.exec(cmd)
      .then(function (res) {
        if (destroyed) return;
        btn.disabled = false;
        if (res.errno !== 0) {
          logErr('导出失败: ' + (res.stderr || ('errno=' + res.errno)));
          toast('导出失败');
          return;
        }
        logOk('日志已导出: ' + path);
        toast('已导出到 Download');
      })
      .catch(function (e) {
        if (destroyed) return;
        btn.disabled = false;
        logErr('导出异常: ' + ((e && e.message) || e));
      });
  }

  /* ---------- 模块信息 ---------- */
  function loadModuleInfo() {
    var info = getModuleInfo();
    if (!info) return;
    if (info.name) {
      document.querySelector('header h1').textContent = info.name;
      var hg = $('hero-greeting');
      if (hg) hg.textContent = info.name;
    }
    var v = info.versionCode || info.version;
    if (v) $('version-chip').textContent = 'v' + v;
  }

  /* ---------- 重启菜单 ---------- */
  var RESTART_ACTIONS = {
    powerkeeper: { label: '重启 PowerKeeper', cmd: 'restart_pk', confirm: false },
    joyose: { label: '重启 Joyose', cmd: 'restart_joyose', confirm: false },
    systemui: { label: '重启 SystemUI', cmd: 'restart_systemui', confirm: false },
    reboot: { label: '重启手机', cmd: 'reboot', confirm: true }
  };

  function showRestartSheet() {
    var sheet = $('restart-sheet');
    if (sheet) sheet.classList.add('show');
  }
  function hideRestartSheet() {
    var sheet = $('restart-sheet');
    if (sheet) sheet.classList.remove('show');
  }

  function doRestartAction(name) {
    var def = RESTART_ACTIONS[name];
    if (!def) return;
    if (def.confirm) {
      uiConfirm('确认重启手机？当前页面将断开。', { okText: '重启', danger: true }).then(function (ok) {
        if (ok) doRestartExec(def);
      });
      return;
    }
    doRestartExec(def);
  }

  function doRestartExec(def) {
    hideRestartSheet();
    logSep();
    logWarn('[restart] ' + def.label + '…');
    var cmd = def.cmd ? shCmd(def.cmd) : '';
    if (!cmd) return;
    api.exec(cmd)
      .then(function (res) {
        if (destroyed) return;
        if (res.errno !== 0) {
          logErr('[restart] 失败: ' + (res.stderr || ('errno=' + res.errno)));
          toast('重启失败');
          return;
        }
        logOk('[restart] ' + def.label + ' 完成');
        toast(def.label + ' 完成');
      })
      .catch(function (e) {
        if (destroyed) return;
        logErr('[restart] 异常: ' + ((e && e.message) || e));
      });
  }

  /* ---------- 主题切换 ---------- */
  var THEME_KEY = 'asphyxia_theme';
  var THEME_ICONS = {
    light: 'M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zM2 13h2c.55 0 1-.45 1-1s-.45-1-1-1H2c-.55 0-1 .45-1 1s.45 1 1 1zm18 0h2c.55 0 1-.45 1-1s-.45-1-1-1h-2c-.55 0-1 .45-1 1s.45 1 1 1zM11 2v2c0 .55.45 1 1 1s1-.45 1-1V2c0-.55-.45-1-1-1s-1 .45-1 1zm0 18v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1zM5.99 4.58c-.39-.39-1.03-.39-1.41 0-.39.39-.39 1.03 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0s.39-1.03 0-1.41L5.99 4.58zm12.37 12.37c-.39-.39-1.03-.39-1.41 0-.39.39-.39 1.03 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0 .39-.39.39-1.03 0-1.41l-1.06-1.06zm1.06-10.96c.39-.39.39-1.03 0-1.41-.39-.39-1.03-.39-1.41 0l-1.06 1.06c-.39-.39.39-1.03 0 1.41s1.03.39 1.41 0l1.06-1.06zM7.05 18.36c.39-.39.39-1.03 0-1.41-.39-.39-1.03-.39-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06z',
    dark: 'M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9 9-4.03 9-9c0-.46-.04-.92-.1-1.36-.98 1.37-2.58 2.26-4.4 2.26-2.98 0-5.4-2.42-5.4-5.4 0-1.81.89-3.42 2.26-4.4-.44-.06-.9-.1-1.36-.1z'
  };
  function getThemePref() {
    try { return localStorage.getItem(THEME_KEY) || 'auto'; } catch (e) { return 'auto'; }
  }
  function applyTheme(t) {
    var root = document.documentElement;
    if (t === 'dark') root.setAttribute('data-theme', 'dark');
    else if (t === 'light') root.setAttribute('data-theme', 'light');
    else root.removeAttribute('data-theme');
    /* 图标显示「再次点击后将切换到的主题」：当前 light（下次点击→dark）显示月亮；
       否则（dark→auto / auto→light）显示太阳 */
    var icon = $('theme-icon');
    if (icon) {
      icon.setAttribute('d', (t === 'light') ? THEME_ICONS.dark : THEME_ICONS.light);
    }
  }
  function cycleTheme() {
    var cur = getThemePref();
    var next = cur === 'auto' ? 'light' : (cur === 'light' ? 'dark' : 'auto');
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* ignore */ }
    applyTheme(next);
  }

  /* ---------- 初始化 ---------- */
  function init() {
    if (!api) {
      $('banner').classList.add('show');
      $('module-sub').textContent = '桥接脚本缺失，请重装模块';
      return;
    }

    MOD_DIR = resolveModuleDir();
    var info = getModuleInfo();
    var sub = MOD_DIR;
    var enabled = info && (info.enabled === true || info.enabled === 'true');
    if (enabled) sub += ' · 已启用';
    $('module-sub').textContent = sub;
    var hs = $('hero-subtitle');
    if (hs) hs.textContent = enabled ? '模块已启用' : '模块未启用';

    if (!api.available) {
      $('banner').classList.add('show');
      $('module-sub').textContent = MOD_DIR + '（桥不可用）';
      return;
    }

    renderActions();
    document.querySelectorAll('#tabbar .tab-btn').forEach(function (b) {
      b.addEventListener('click', function () { switchTab(b.dataset.tab); });
    });
    var btnClear = $('btn-clear-log');
    if (btnClear) btnClear.addEventListener('click', clearLog);
    var btnRefresh = $('btn-refresh-status');
    if (btnRefresh) btnRefresh.addEventListener('click', refreshStatus);
    var btnExport = $('btn-export-log');
    if (btnExport) btnExport.addEventListener('click', exportLog);
    var wlsAddBtn = $('wls-add-btn');
    if (wlsAddBtn) wlsAddBtn.addEventListener('click', addWls);
    var wlsInput = $('wls-input');
    if (wlsInput) {
      wlsInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          addWls();
        }
      });
    }
    var btnTheme = $('btn-theme');
    if (btnTheme) btnTheme.addEventListener('click', cycleTheme);
    var btnRestart = $('btn-restart');
    if (btnRestart) btnRestart.addEventListener('click', showRestartSheet);
    var restartClose = $('restart-close');
    if (restartClose) restartClose.addEventListener('click', hideRestartSheet);
    var restartSheet = $('restart-sheet');
    if (restartSheet) restartSheet.addEventListener('click', function (e) {
      if (e.target === restartSheet) hideRestartSheet();
    });
    var dlgOk = $('dlg-ok');
    if (dlgOk) dlgOk.addEventListener('click', function () { settleConfirm(true); });
    var dlgCancel = $('dlg-cancel');
    if (dlgCancel) dlgCancel.addEventListener('click', function () { settleConfirm(false); });
    var dlgOverlay = $('confirm-dlg');
    if (dlgOverlay) dlgOverlay.addEventListener('click', function (e) {
      if (e.target === dlgOverlay) settleConfirm(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && dlgCurrent) settleConfirm(false);
    });
    document.querySelectorAll('.sheet-circle').forEach(function (b) {
      b.addEventListener('click', function () { doRestartAction(b.dataset.restart); });
    });
    var wlsSearch = $('wls-search');
    if (wlsSearch) {
      wlsSearch.addEventListener('input', function () {
        if (wlsDebounceTimer) clearTimeout(wlsDebounceTimer);
        wlsDebounceTimer = setTimeout(function () {
          wlsFilter = wlsSearch.value.trim();
          renderWlsItems();
        }, 180);
      });
    }
    var wlsRefresh = $('btn-wls-refresh');
    if (wlsRefresh) wlsRefresh.addEventListener('click', refreshWlsList);
    var backupRefresh = $('btn-backup-refresh');
    if (backupRefresh) backupRefresh.addEventListener('click', refreshBackups);
    var cfgPath = $('config-path');
    if (cfgPath) cfgPath.textContent = MOD_DIR + '/config/';
    var infoDir = $('info-dir');
    if (infoDir) infoDir.textContent = MOD_DIR;
    applyTheme(getThemePref());
    /* auto 模式下跟随系统主题实时变化（兼容旧 WebView 仅 addListener） */
    if (window.matchMedia) {
      var mql = window.matchMedia('(prefers-color-scheme: dark)');
      function onThemeChange() {
        if (getThemePref() === 'auto') applyTheme('auto');
      }
      if (mql && mql.addEventListener) mql.addEventListener('change', onThemeChange);
      else if (mql && mql.addListener) mql.addListener(onThemeChange);
    }

    window.addEventListener('pagehide', function () {
      destroyed = true;
      if (autoTimer) {
        clearInterval(autoTimer);
        autoTimer = null;
      }
    });
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) {
        if (autoTimer) {
          clearInterval(autoTimer);
          autoTimer = null;
        }
      } else if (!autoTimer && !destroyed) {
        autoTimer = setInterval(autoRefresh, AUTO_REFRESH_MS);
      }
    });

    loadModuleInfo();
    refreshStatus();
    refreshBackups();
    renderWlsTabs();
    switchWls(WLS_DEFS[0].name);
    autoTimer = setInterval(autoRefresh, AUTO_REFRESH_MS);
  }

  function autoRefresh() {
    if (!state.refreshing && !destroyed) refreshStatus();
  }

  document.addEventListener('DOMContentLoaded', init);
})();
