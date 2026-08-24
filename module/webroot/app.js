(function () {
  'use strict';

  var api = window.ksuApi;

  /* ---------- 常量 ---------- */
  var FALLBACK_MOD_ID = 'HyperOS-3CO';
  var MOD_DIR = '/data/adb/modules/' + FALLBACK_MOD_ID;
  var AUTO_REFRESH_MS = 60000;
  var REFRESH_DELAY_MS = 500;
  var SPAWN_TIMEOUT_MS = 120000;
  var LOG_MAX_NODES = 1600;

  /* 5 个开关，与 action.sh CONFIG_KEYS / check_status.sh 输出对应 */
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
    { id: 10, label: '即时恢复', cmd: 'unfreeze', confirm: true, danger: true }
  ];

  var state = {
    flags: {},
    busy: false,
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
    var div = document.createElement('div');
    div.className = 'log-line' + (cls ? ' ' + cls : '');
    var now = new Date();
    function p2(n) { return (n < 10 ? '0' : '') + n; }
    div.textContent = '[' + p2(now.getHours()) + ':' + p2(now.getMinutes()) + ':' + p2(now.getSeconds()) + '] ' + stripAnsi(text);
    box.appendChild(div);
    while (box.childElementCount > LOG_MAX_NODES) box.removeChild(box.firstChild);
    box.scrollTop = box.scrollHeight;
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

  /* 仅接受固定模式，避免 innerHTML 注入面 */
  function setRunStatus(mode) {
    var el = $('run-status');
    if (!el) return;
    el.textContent = '';
    if (mode === 'busy') {
      var sp = document.createElement('span');
      sp.className = 'spinner';
      el.appendChild(sp);
      el.appendChild(document.createTextNode('执行中…'));
    }
  }

  function toast(msg) { if (api) api.toast(msg); }

  function shCmd(cmd) { return 'sh ' + MOD_DIR + '/action.sh ' + cmd; }

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
        var cls = 'ok';
        if (t >= 400) cls = 'warn';
        if (cap <= 15) cls = 'danger';
        batt.className = 'v ' + cls;
        batt.textContent =
          s.battery.status + ' · ' + s.battery.capacity + '% · ' +
          (t / 10).toFixed(1) + '°C';
        batt.title = '电流 ' + s.battery.current + 'uA · 电压 ' + s.battery.voltage + 'uV';
      } else {
        batt.className = 'v';
        batt.textContent = '-';
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
    el.className = 'v';
    el.textContent = (val == null || val === '') ? '-' : val;
  }

  /* ---------- 开关 ---------- */
  function renderToggles(flags) {
    var wrap = $('toggles');
    if (!wrap) return;
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
      if (!window.confirm('开启「' + def.label + '」可能影响充电/温控，确认继续？')) {
        input.checked = false;
        return;
      }
    }

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
    if (state.busy) {
      toast('有任务正在执行，请稍候');
      return;
    }
    if (btn.dataset.confirm === '1') {
      if (!window.confirm('确认执行「' + btn.textContent.replace(/^\d+/, '').trim() + '」？')) return;
    }
    state.busy = true;
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
      state.busy = false;
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

    var child = api.spawn('sh', [MOD_DIR + '/action.sh', btn.dataset.cmd]);
    watchdog = setTimeout(function () {
      if (!settled) {
        logErr('执行超时（' + Math.round(SPAWN_TIMEOUT_MS / 1000) + 's），已复位');
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
    if (destroyed || state.busy || state.refreshing) return;
    state.refreshing = true;
    var seq = ++refreshSeq;
    var btn = $('btn-refresh-status');
    if (btn) btn.disabled = true;
    var t0 = Date.now();
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
      .then(function () {
        if (destroyed) return;
        if (seq === refreshSeq) {
          state.refreshing = false;
          var b2 = $('btn-refresh-status');
          if (b2) b2.disabled = false;
        }
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
          del.textContent = '删除';
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
    if (!window.confirm('确认删除备份 ' + name + ' ？')) return;
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

  function renderWlsItems() {
    var listEl = $('wls-list');
    var sumEl = $('wls-summary');
    if (!listEl || !sumEl) return;
    var kw = wlsFilter.toLowerCase();
    var shown = kw ? wlsPkgs.filter(function (p) { return p.toLowerCase().indexOf(kw) >= 0; }) : wlsPkgs;
    sumEl.textContent = shown.length + ' / ' + wlsPkgs.length + ' 个';
    listEl.innerHTML = '';
    if (!shown.length) {
      listEl.innerHTML = '<div class="log-empty">' + (wlsPkgs.length ? '无匹配结果' : '名单为空') + '</div>';
      return;
    }
    shown.forEach(function (pkg) {
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
      del.addEventListener('click', function () { removeWls(pkg, del); });
      row.appendChild(nm);
      row.appendChild(del);
      listEl.appendChild(row);
    });
  }

  function refreshWlsList() {
    if (!currentWls) return;
    var reqName = currentWls;
    api.exec(shCmd('wl_sys_list ' + currentWls))
      .then(function (res) {
        if (destroyed || reqName !== currentWls) return;
        wlsPkgs = [];
        String(res.stdout).split('\n').forEach(function (line) {
          var p = line.trim();
          if (p && isValidPkg(p)) wlsPkgs.push(p);
        });
        renderWlsItems();
      })
      .catch(function (e) {
        if (destroyed) return;
        var listEl = $('wls-list');
        if (listEl) listEl.innerHTML = '<div class="log-empty">读取失败</div>';
        logErr('系统白名单异常: ' + ((e && e.message) || e));
      });
  }

  function addWls() {
    var input = $('wls-input');
    if (!input || !currentWls) return;
    var pkg = input.value.trim();
    if (!pkg) { toast('请输入包名'); return; }
    if (!isValidPkg(pkg)) { logErr('非法包名，已拒绝: ' + pkg); return; }
    input.disabled = true;
    api.exec(shCmd('wl_sys_add ' + currentWls + ' ' + pkg))
      .then(function (res) {
        if (destroyed) return;
        input.disabled = false;
        if (res.errno !== 0) {
          logErr(res.stderr || ('添加失败 errno=' + res.errno));
          toast('添加失败');
          return;
        }
        if (res.stdout) logLine(res.stdout.trim());
        input.value = '';
        toast('已添加');
        refreshWlsList();
      })
      .catch(function (e) {
        if (destroyed) return;
        input.disabled = false;
        logErr('添加异常: ' + ((e && e.message) || e));
      });
  }

  function removeWls(pkg, delBtn) {
    if (!window.confirm('确认从「' + currentWls + '」移除 ' + pkg + ' ？\n移除后该应用可能被息屏冻结/后台清理。')) return;
    delBtn.disabled = true;
    api.exec(shCmd('wl_sys_remove ' + currentWls + ' ' + pkg))
      .then(function (res) {
        if (destroyed) return;
        delBtn.disabled = false;
        if (res.errno !== 0) {
          logErr(res.stderr || '移除失败');
          toast('移除失败');
          return;
        }
        if (res.stdout) logLine(res.stdout.trim());
        toast('已移除');
        refreshWlsList();
      })
      .catch(function (e) {
        if (destroyed) return;
        delBtn.disabled = false;
        logErr('移除异常: ' + ((e && e.message) || e));
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
    if (info.name) document.querySelector('header h1').textContent = info.name;
    var v = info.versionCode || info.version;
    if (v) $('version-chip').textContent = 'v' + v;
  }

  /* ---------- 重启菜单 ---------- */
  var RESTART_ACTIONS = {
    powerkeeper: { label: '重启 PowerKeeper', cmd: 'restart_pk', confirm: false },
    joyose: { label: '重启 Joyose', cmd: '', confirm: false },
    systemui: { label: '重启 SystemUI', cmd: '', confirm: false },
    reboot: { label: '重启手机', cmd: '', confirm: true }
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
      if (!window.confirm('确认重启手机？当前页面将断开。')) return;
    }
    hideRestartSheet();
    logSep();
    logWarn('[restart] ' + def.label + '…');
    var cmd = '';
    if (name === 'powerkeeper') {
      cmd = shCmd('restart_pk');
    } else if (name === 'joyose') {
      cmd = 'am force-stop com.xiaomi.joyose && am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose';
    } else if (name === 'systemui') {
      cmd = 'am force-stop com.android.systemui';
    } else if (name === 'reboot') {
      cmd = 'reboot';
    }
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
    if (info && (info.enabled === true || info.enabled === 'true')) sub += ' · 已启用';
    $('module-sub').textContent = sub;

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
    document.querySelectorAll('.sheet-circle').forEach(function (b) {
      b.addEventListener('click', function () { doRestartAction(b.dataset.restart); });
    });
    var wlsSearch = $('wls-search');
    if (wlsSearch) wlsSearch.addEventListener('input', function () {
      wlsFilter = wlsSearch.value.trim();
      renderWlsItems();
    });
    var wlsRefresh = $('btn-wls-refresh');
    if (wlsRefresh) wlsRefresh.addEventListener('click', refreshWlsList);
    applyTheme(getThemePref());
    /* auto 模式下跟随系统主题实时变化 */
    if (window.matchMedia) {
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
        if (getThemePref() === 'auto') applyTheme('auto');
      });
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
    if (!state.busy && !state.refreshing && !destroyed) refreshStatus();
  }

  document.addEventListener('DOMContentLoaded', init);
})();
