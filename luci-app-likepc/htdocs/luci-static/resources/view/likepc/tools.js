'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require rpc';
'require ui';
'require uci';

var SCRIPT = '/usr/share/likepc/likepc.sh';
var INIT_SCRIPT = '/etc/init.d/likepc';
var LOG_FILE = '/tmp/likepc.log';
var STATE_FILE = '/tmp/likepc.state';
var MAC_FILE = '/tmp/likepc.mac';
var INFO_FILE = '/tmp/likepc.info';
var ALERT_FILE = '/tmp/likepc.alert';
var DEPS_FILE = '/tmp/likepc.deps';
var HARDEN_FILE = '/tmp/likepc.harden';

var els = {};
var pollStarted = false;

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function execCmd(path, args) {
	return fs.exec(path, args).then(function(res) {
		return res || { code: -1, stdout: '', stderr: '' };
	}).catch(function(err) {
		return { code: -1, stdout: '', stderr: (err && err.message) || '' };
	});
}

function readText(path) {
	return fs.read(path).then(function(res) {
		return res || '';
	}).catch(function() {
		return '';
	});
}

function parseState(text) {
	var state = {};

	(text || '').split('\n').forEach(function(line) {
		var pos = line.indexOf('=');

		if (pos > 0)
			state[line.substring(0, pos)] = line.substring(pos + 1);
	});

	return state;
}

function notify(text, type) {
	ui.addNotification(null, E('p', {}, text), type || 'info');
}

/* 体检报告每行：等级|名称|说明；等级 sw 的行是各开关的状态 */
function parseReport(text) {
	var rows = [], sw = {};

	(text || '').split('\n').forEach(function(line) {
		var p = line.split('|');

		if (p.length < 3)
			return;

		if (p[0] == 'sw')
			sw[p[1]] = p[2];
		else
			rows.push({ level: p[0], name: p[1], detail: p[2] });
	});

	return { rows: rows, sw: sw };
}

var HD_MARK = { ok: '✓', bad: '✕', warn: '!', info: '·' };

function hdClass(level) {
	return level == 'ok' ? 'ca-hd-ok'
		: (level == 'bad' ? 'ca-hd-bad'
		: (level == 'warn' ? 'ca-hd-warn' : 'ca-hd-info'));
}

function serviceRunning() {
	return L.resolveDefault(callServiceList('likepc'), {}).then(function(res) {
		var running = false;

		try {
			var instances = (res['likepc'] || {}).instances || {};

			Object.keys(instances).forEach(function(name) {
				if (instances[name]['running'])
					running = true;
			});
		}
		catch (e) { }

		return running;
	});
}

function setTxt(el, text, cls) {
	if (!el)
		return;

	el.textContent = text;

	if (cls !== undefined)
		el.className = cls;
}

function attached(el) {
	return el && document.body.contains(el);
}

/* ------------------------------------------------------------------ 样式 */
var CSS = [
	'.ca-hero{margin-bottom:16px}',
	'.ca-head{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:0 0 10px}',
	'.ca-title{font-size:17px;font-weight:700;margin:0}',
	'.ca-badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;',
	'padding:3px 11px;border-radius:999px;border:1px solid rgba(127,127,127,.35);',
	'background:rgba(127,127,127,.10);color:inherit;white-space:nowrap}',
	'.ca-badge::before{content:"";width:8px;height:8px;border-radius:50%;background:currentColor;opacity:.9}',
	'.ca-ok{color:#2fa84f;border-color:rgba(47,168,79,.45);background:rgba(47,168,79,.12)}',
	'.ca-bad{color:#e0564f;border-color:rgba(224,86,79,.45);background:rgba(224,86,79,.12)}',
	'.ca-idle{color:inherit;opacity:.75}',
	'.ca-cards{display:flex;flex-wrap:wrap;gap:10px}',
	'.ca-card{flex:1 1 210px;min-width:185px;background:rgba(127,127,127,.08);',
	'border:1px solid rgba(127,127,127,.18);border-radius:10px;padding:10px 12px}',
	'.ca-k{font-size:12px;opacity:.72;margin-bottom:5px}',
	'.ca-v{font-size:14px;font-weight:600;word-break:break-all;line-height:1.45}',
	'.ca-sub{font-size:12px;opacity:.7;margin-top:4px;font-weight:400;word-break:break-all}',
	'.ca-mono{font-family:ui-monospace,SFMono-Regular,Consolas,"Liberation Mono",monospace;font-size:13px}',
	'.ca-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}',
	'.ca-chip{font-family:ui-monospace,Consolas,monospace;font-size:12.5px;padding:5px 10px;',
	'border-radius:8px;background:rgba(127,127,127,.12);border:1px solid rgba(127,127,127,.25);white-space:nowrap}',
	'.ca-chip-cur{background:rgba(47,168,79,.16);border-color:rgba(47,168,79,.55);font-weight:700}',
	'.ca-btnrow{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}',
	'.ca-tools{display:flex;flex-wrap:wrap;gap:12px}',
	'.ca-tool{flex:1 1 290px;min-width:270px;background:rgba(127,127,127,.08);',
	'border:1px solid rgba(127,127,127,.18);border-radius:10px;padding:12px}',
	'.ca-tool h4{margin:0 0 4px;font-size:13.5px;font-weight:700}',
	'.ca-note{font-size:12px;opacity:.72;line-height:1.65;margin:6px 0 0}',
	'.ca-log{font-family:ui-monospace,Consolas,monospace;font-size:12px;line-height:1.55;',
	'background:#12161a;color:#cfd8e3;border-radius:10px;padding:10px 12px;height:280px;',
	'overflow:auto;white-space:pre-wrap;word-break:break-all;margin:0}',
	'.ca-warn{color:#d99a2b}',
	'.ca-alert{display:flex;flex-wrap:wrap;align-items:flex-start;gap:10px;margin:0 0 14px;',
	'padding:11px 14px;border-radius:10px;border:1px solid rgba(224,86,79,.5);',
	'background:rgba(224,86,79,.10);color:#d9504a}',
	'.ca-alert.crit{border-color:rgba(224,86,79,.9);background:rgba(224,86,79,.20)}',
	'.ca-alert-icon{font-size:17px;line-height:1.2}',
	'.ca-alert-body{flex:1 1 240px;min-width:200px}',
	'.ca-alert-title{margin:0 0 2px;font-size:13.5px;font-weight:700}',
	'.ca-alert-line{margin:0;font-size:12.5px;line-height:1.55;opacity:.92}',
	'.ca-env{font-size:13px;line-height:1.9}',
	'.ca-env-key{display:inline-block;min-width:92px;opacity:.72}',
	'.ca-pill{display:inline-block;font-size:11.5px;font-weight:700;padding:1px 8px;',
	'border-radius:999px;background:rgba(127,127,127,.16);border:1px solid rgba(127,127,127,.3)}',
	'.ca-pill.ca-ok{color:#2fa84f;border-color:rgba(47,168,79,.45);background:rgba(47,168,79,.12)}',
	'.ca-hd{display:flex;flex-direction:column;gap:6px;font-size:13px}',
	'.ca-hd-row{display:flex;gap:10px;align-items:flex-start;padding:7px 10px;border-radius:8px;',
	'background:rgba(127,127,127,.07);border:1px solid rgba(127,127,127,.14)}',
	'.ca-hd-mark{flex:0 0 16px;text-align:center;font-weight:700}',
	'.ca-hd-name{flex:0 0 118px;font-weight:600}',
	'.ca-hd-detail{flex:1 1 auto;opacity:.85;line-height:1.6;word-break:break-word}',
	'.ca-hd-ok{color:#2fa84f}',
	'.ca-hd-warn{color:#d99a2b}',
	'.ca-hd-bad{color:#e0564f}',
	'.ca-hd-info{opacity:.55}'
].join('');

/* ------------------------------------------------------------------ 数据刷新 */
function refreshAll() {
	if (!attached(els.svc) && !attached(els.log) && !attached(els.hdList))
		return;

	return Promise.all([
		serviceRunning(),
		readText(STATE_FILE),
		readText(MAC_FILE),
		readText(INFO_FILE),
		readText(LOG_FILE),
		readText(ALERT_FILE),
		readText(HARDEN_FILE)
	]).then(function(res) {
		var running = res[0];
		var state = parseState(res[1]);
		var mac = parseState(res[2]);
		var info = parseState(res[3]);
		var log = res[4];
		var alert = parseState(res[5]);
		var report = parseReport(res[6]);

		/* 顶部徽章 */
		if (attached(els.svc)) {
			setTxt(els.svc, running ? _('服务运行中') : _('服务未运行'), 'ca-badge ' + (running ? 'ca-ok' : 'ca-bad'));
			setTxt(els.sub, running
				? _('开机运行 / 防掉线检测已生效')
				: _('关闭“防掉线检测”时只在开机时检测一次，进程跑完即退出属正常'));
		}

		if (attached(els.net)) {
			var isOk = state['status'] == 'ok';
			var isFail = state['status'] == 'fail';
			setTxt(els.net, isOk ? _('外网正常') : (isFail ? _('外网异常') : _('状态未知')),
				'ca-badge ' + (isOk ? 'ca-ok' : (isFail ? 'ca-bad' : 'ca-idle')));
		}

		/* 出网特征体检 */
		if (attached(els.hdList)) {
			els.hdList.replaceChildren.apply(els.hdList, report.rows.map(function(r) {
				return E('div', { 'class': 'ca-hd-row' }, [
					E('span', { 'class': 'ca-hd-mark ' + hdClass(r.level) }, HD_MARK[r.level] || '·'),
					E('span', { 'class': 'ca-hd-name' }, r.name),
					E('span', { 'class': 'ca-hd-detail' }, r.detail)
				]);
			}));

			[ 'ipv6', 'offload', 'sig', 'dhcp', 'quiet', 'routing' ].forEach(function(k) {
				var el = els['hd_' + k];
				var v = report.sw[k];

				if (!el)
					return;

				if (v == '1')
					setTxt(el, _('已加固'), 'ca-pill ca-ok');
				else if (v == '0')
					setTxt(el, _('未加固'), 'ca-pill ca-idle');
				else
					setTxt(el, _('未知'), 'ca-pill ca-idle');
			});
		}

		/* 连续检测失败告警横幅 */
		if (attached(els.alert)) {
			var lvl = alert['level'];

			if (lvl == 'warn' || lvl == 'crit') {
				els.alertKey = lvl + '|' + (alert['count'] || '') + '|' + (alert['time'] || '');

				if (els.alertShown != els.alertKey) {
					els.alertShown = els.alertKey;
					setTxt(els.alertTitle, lvl == 'crit' ? _('外网持续不通') : _('外网连续不通'));
					setTxt(els.alertMsg, alert['message'] || _('外网连续不通'));
					setTxt(els.alertTime, alert['time'] ? _('最近一次：%s').format(alert['time']) : '');
					setTxt(els.alertErr, state['status'] == 'fail' && state['message']
						? _('最近一次提示：%s').format(state['message'])
						: '');
				}

				els.alert.className = 'ca-alert' + (lvl == 'crit' ? ' crit' : '');
				els.alert.style.display = '';
			}
			else {
				els.alertShown = '';
				els.alert.style.display = 'none';
			}
		}

		/* 卡片 */
		if (attached(els.macCur))
			setTxt(els.macCur, mac['current'] || info['wan_mac'] || '-', 'ca-v ca-mono');
		if (attached(els.macDev))
			setTxt(els.macDev, _('WAN 设备：%s').format(mac['device'] || info['wan_device'] || _('未识别')));

		if (attached(els.lastCheck)) {
			var msg = state['message'] || _('暂无检测记录');
			var t = state['time'] ? '（' + state['time'] + '）' : '';
			setTxt(els.lastCheck, msg + t, 'ca-v');
		}

		if (attached(els.fwNote)) {
			var envKey = [ info['fw_ver'], info['fw_desc'], info['fw_rules'], info['string'], info['ttl'] ].join('|');

			if (els.fwDone != envKey) {
				els.fwDone = envKey;

				var rows = [
					envRow(_('防火墙版本'), E('span', {}, [
						info['fw_desc'] || _('未检测到 iptables / nft'),
						' ',
						E('span', { 'class': 'ca-pill' }, info['fw_name'] || 'unknown')
					])),
					envRow(_('校园网规则'), info['fw_rules'] == '1'
						? E('span', { 'class': 'ca-warn' }, _('已加载'))
						: _('未加载（点上面的「一键添加防火墙规则」即可）'))
				];

				if (info['fw_ver'] == '3') {
					rows.push(envRow(_('string 匹配'), info['string'] == '1'
						? _('可用')
						: _('缺失，需 iptables-mod-filter')));
					rows.push(envRow(_('TTL target'), info['ttl'] == '1'
						? _('可用')
						: _('缺失，需 iptables-mod-ipopt')));
				}
				else if (info['fw_ver'] == '4') {
					rows.push(envRow(_('规则位置'), '/etc/config/firewall → include (nftables)'));

					if (info['probe_block'] == '1')
						rows.push(envRow(_('探测包屏蔽'), _('按目标地址拦截：%s').format(info['probe_cidr'] || '-')));
					else
						rows.push(envRow(_('探测包屏蔽'), _('已在设置里关闭')));
				}

				if (info['deps_missing'])
					rows.push(envRow(_('缺少依赖'), E('span', { 'class': 'ca-warn' }, info['deps_missing'])));

				els.fwNote.innerHTML = '';
				rows.forEach(function(row) { els.fwNote.appendChild(row); });
			}
		}

		if (attached(els.pcNote)) {
			setTxt(els.pcNote, info['pc_fake'] == '1'
				? _('当前 WAN 主机名：%s（已伪装）').format(info['wan_host'] || '-')
				: _('当前未伪装；一键伪装后会设置随机主机名 / MSFT 5.0 / client-id'),
				'ca-note');
		}

		/* MAC 池芯片 */
		if (attached(els.chips) && els.chipsDone != (mac['pool'] || '')) {
			var pool = (mac['pool'] || '').split(',').filter(function(x) { return x.length; });
			var cur = mac['current'] || '';
			var idx = parseInt(mac['index'] || '0', 10);

			els.chipsDone = mac['pool'] || '';
			els.chips.innerHTML = '';

			if (!pool.length) {
				els.chips.appendChild(E('span', { 'class': 'ca-note' },
					_('还没有 MAC 池，点“重新生成 5 个 MAC”或开启防拉黑后自动生成')));
			}
			else {
				pool.forEach(function(m, i) {
					els.chips.appendChild(E('span', {
						'class': 'ca-chip' + (i === idx || m === cur ? ' ca-chip-cur' : '')
					}, m));
				});
			}
		}

		/* 日志 */
		if (attached(els.log)) {
			var lines = (log || '').replace(/\s+$/, '').split('\n').filter(function(l) { return l.length; });
			els.log.textContent = lines.length
				? lines.slice(-60).map(function(l) { return l.replace(/^\d+\s+/, ''); }).join('\n')
				: _('暂无日志');
			els.log.scrollTop = els.log.scrollHeight;
		}
	});
}

function startPolling() {
	if (pollStarted)
		return;

	pollStarted = true;

	setTimeout(function() {
		refreshAll();
		poll.add(refreshAll, 5);
	}, 100);
}

function runAction(action, label, checkDeps) {
	return execCmd(SCRIPT, [ action ]).then(function(res) {
		return readText(LOG_FILE).then(function(txt) {
			var lines = (txt || '').replace(/\s+$/, '').split('\n').filter(function(l) { return l.length; });
			var last = lines.length ? lines[lines.length - 1].replace(/^\d+\s+/, '').replace(/^\[[^\]]*\]\s*/, '') : '';

			notify(last || label || _('执行完成'), res.code === 0 ? 'info' : 'warning');

			return refreshAll();
		}).then(function() {
			if (checkDeps)
				return notifyMissingDeps();
		});
	});
}

/* 缺依赖时弹一条明确的提示，告诉用户缺什么、要么自己编进固件要么在线装 */
function notifyMissingDeps() {
	return readText(DEPS_FILE).then(function(txt) {
		var deps = parseState(txt);
		var miss = deps['missing'];

		if (!miss)
			return;

		var cmd = deps['command'] || ('opkg update && opkg install ' + miss);

		notify(_('缺少依赖：%s。本插件刻意没把它写进编译依赖，请自行在固件里编入，或在设备上执行：%s')
			.format(miss, cmd), 'warning');
	});
}

function toolButton(title, action, style, checkDeps) {
	var btn = E('button', { 'class': 'cbi-button cbi-button-' + (style || 'action') }, title);

	btn.addEventListener('click', function() {
		btn.disabled = true;
		notify(_('正在执行：%s').format(title));

		return runAction(action, title, checkDeps).then(function() {
			btn.disabled = false;
		});
	});

	return btn;
}

function envRow(key, val) {
	return E('div', {}, [
		E('span', { 'class': 'ca-env-key' }, key),
		val
	]);
}

function toolCard(title, desc, buttons) {
	return E('div', { 'class': 'ca-tool' }, [
		E('h4', {}, title),
		E('p', { 'class': 'ca-note' }, desc),
		E('div', { 'class': 'ca-btnrow' }, buttons)
	]);
}

/* ------------------------------------------------------------------ 状态卡片 */
function renderHero() {

	els.svc = E('span', { 'class': 'ca-badge ca-idle' }, _('读取中…'));
	els.sub = E('small', { 'class': 'ca-note' }, '');
	els.net = E('span', { 'class': 'ca-badge ca-idle' }, _('读取中…'));
	els.macCur = E('div', { 'class': 'ca-v ca-mono' }, '-');
	els.macDev = E('small', { 'class': 'ca-sub' }, '');
	els.lastCheck = E('div', { 'class': 'ca-v' }, _('读取中…'));
	els.chips = E('div', { 'class': 'ca-chips' }, []);

	/* 连续检测失败告警横幅 */
	els.alertTitle = E('p', { 'class': 'ca-alert-title' }, '');
	els.alertMsg = E('p', { 'class': 'ca-alert-line' }, '');
	els.alertTime = E('p', { 'class': 'ca-alert-line' }, '');
	els.alertErr = E('p', { 'class': 'ca-alert-line' }, '');

	var btnAlertClear = E('button', { 'class': 'cbi-button cbi-button-reset' }, _('清除告警'));
	btnAlertClear.addEventListener('click', function() {
		btnAlertClear.disabled = true;
		return runAction('alertclear', _('已清除告警')).then(function() {
			btnAlertClear.disabled = false;
		});
	});

	els.alert = E('div', { 'class': 'ca-alert', 'style': 'display:none' }, [
		E('span', { 'class': 'ca-alert-icon' }, '⚠'),
		E('div', { 'class': 'ca-alert-body' }, [ els.alertTitle, els.alertMsg, els.alertTime, els.alertErr ]),
		btnAlertClear
	]);

	var btnCheck = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('立即检测外网'));
	var btnRecover = E('button', { 'class': 'cbi-button cbi-button-action' }, _('检测并尝试恢复'));
	var btnRestart = E('button', { 'class': 'cbi-button cbi-button-action' }, _('启动 / 重启服务'));
	var btnStop = E('button', { 'class': 'cbi-button cbi-button-reset' }, _('停止服务'));

	btnCheck.addEventListener('click', function() {
		btnCheck.disabled = true;
		notify(_('正在检测外网…'));

		return execCmd(SCRIPT, [ 'check' ]).then(function() {
			btnCheck.disabled = false;
			return readText(STATE_FILE).then(function(txt) {
				var state = parseState(txt);
				notify(state['message'] || _('检测完成'), state['status'] == 'fail' ? 'warning' : 'info');
				return refreshAll();
			});
		});
	});

	btnRecover.addEventListener('click', function() {
		btnRecover.disabled = true;
		notify(_('正在检测并尝试恢复…'));

		return execCmd(SCRIPT, [ 'recover' ]).then(function() {
			btnRecover.disabled = false;
			return readText(STATE_FILE).then(function(txt) {
				var state = parseState(txt);
				notify(state['message'] || _('处理完成'), state['status'] == 'fail' ? 'warning' : 'info');
				return refreshAll();
			});
		});
	});

	btnRestart.addEventListener('click', function() {
		return execCmd(INIT_SCRIPT, [ 'restart' ]).then(function(res) {
			notify(res.code === 0 ? _('服务已启动 / 重启') : _('服务操作失败：%d').format(res.code));
			return refreshAll();
		});
	});

	btnStop.addEventListener('click', function() {
		return execCmd(INIT_SCRIPT, [ 'stop' ]).then(function(res) {
			notify(res.code === 0 ? _('服务已停止') : _('服务操作失败：%d').format(res.code));
			return refreshAll();
		});
	});

	startPolling();

	return E('div', { 'class': 'ca-hero' }, [
		E('style', {}, CSS),
		E('div', { 'class': 'ca-head' }, [
			E('h3', { 'class': 'ca-title' }, _('模拟pc')),
			els.svc,
			els.net
		]),
		els.sub,
		els.alert,
		E('div', { 'class': 'ca-cards', 'style': 'margin-top:10px' }, [
			E('div', { 'class': 'ca-card' }, [
				E('div', { 'class': 'ca-k' }, _('当前 WAN MAC')),
				els.macCur,
				els.macDev
			]),
			E('div', { 'class': 'ca-card' }, [
				E('div', { 'class': 'ca-k' }, _('最近一次检测')),
				els.lastCheck
			]),
			E('div', { 'class': 'ca-card' }, [
				E('div', { 'class': 'ca-k' }, _('备用的 5 个 MAC（轮换用）')),
				els.chips
			])
		]),
		E('div', { 'class': 'ca-btnrow' }, [ btnCheck, btnRecover, btnRestart, btnStop ])
	]);
}

/* ------------------------------------------------------------------ 出网特征加固 */
function hdButton(label, action, title, style) {
	var btn = E('button', { 'class': 'cbi-button cbi-button-' + (style || 'action') }, label);

	btn.addEventListener('click', function() {
		btn.disabled = true;
		notify(_('正在执行：%s').format(title));

		return runAction(action, title).then(function() {
			btn.disabled = false;
		});
	});

	return btn;
}

function renderHarden() {
	var items = [
		{
			key: 'ipv6',
			title: _('IPv6 全关'),
			desc: _('不再向校园网请求 IPv6 地址和前缀，内网也不发 RA。要前缀这个动作本身就等于声明“我是路由器”，而且内网每台设备都会各自拿到一个全球地址，上游数地址就能数出你有几台设备。代价：内网没有 IPv6 了。'),
			off: 'hd-ipv6', on: 'hd-ipv6-undo',
			warn: _('撤销会把 network / dhcp 配置还原成点「应用」那一刻的样子，这之后你手工改过的网络设置也会一起回退。')
		},
		{
			key: 'offload',
			title: _('关掉流量卸载与限速'),
			desc: _('流量卸载会让已建立的连接绕过 mangle 链，TTL 这类规则时对时不对 —— 这正是“有时一小时被抓、有时几小时没事”的典型成因。代价：CPU 占用上升、转发吞吐下降。'),
			off: 'hd-offload', on: 'hd-offload-undo'
		},
		{
			key: 'sig',
			title: _('统一出网特征（TTL + MSS）'),
			desc: _('出网 TTL 统一为 128（Windows 就是 128，不是 64），TCP MSS 钉死为 1460。防火墙规则里已经带了 TTL 时不重复加，也不会去动主规则那一份。'),
			off: 'hd-sig', on: 'hd-sig-undo'
		},
		{
			key: 'dhcp',
			title: _('DHCP 指纹 + 电脑身份'),
			desc: _('伪装成 Windows 电脑（LAPTOP-XXXXXXX / MSFT 5.0 / client-id 跟随 MAC）。电脑名平时不变 —— 真实电脑的名字是稳定的；只有被拉黑自动换 MAC 时，名字才跟着一起换。'),
			off: 'hd-dhcp', on: 'hd-dhcp-undo',
			extra: [ hdButton(_('换一个电脑身份'), 'pcnewid', _('换一个电脑身份')) ]
		},
		{
			key: 'quiet',
			title: _('掐掉定时联网的服务'),
			desc: _('停掉 umdns、mwan3 健康检查、自动更新检查、DDNS 这类会定时主动往外发东西的服务（撤销时按名单逐个恢复）。原则：任何定时自发联网的行为都是指纹。'),
			off: 'hd-quiet', on: 'hd-quiet-undo'
		},
		{
			key: 'routing',
			title: _('关掉路由 / 组播协议'),
			desc: _('停掉 OSPF、RIP、BGP、PIM、IGMP 代理这类守护进程（bird / babeld / ospfd / ripd / bgpd / pimd / smcroute / igmpproxy 等），并关掉网桥的 IGMP 嗅探。这些协议只有路由器会发，电脑一个都不发。'),
			off: 'hd-routing', on: 'hd-routing-undo'
		}
	];

	els.hdList = E('div', { 'class': 'ca-hd' }, _('点击「重新体检」开始。'));

	var btnHd = E('button', { 'class': 'cbi-button cbi-button-action' }, _('重新体检'));
	btnHd.addEventListener('click', function() {
		btnHd.disabled = true;
		notify(_('正在体检…'));

		return execCmd(SCRIPT, [ 'harden' ]).then(function() {
			btnHd.disabled = false;
			return refreshAll();
		});
	});

	var cards = items.map(function(it) {
		var badge = E('span', { 'class': 'ca-pill ca-idle' }, _('读取中…'));
		var btns = [ hdButton(_('应用'), it.off, it.title, 'apply'), hdButton(_('撤销'), it.on, _('撤销：%s').format(it.title)) ];

		els['hd_' + it.key] = badge;

		(it.extra || []).forEach(function(b) { btns.push(b); });

		return E('div', { 'class': 'ca-tool' }, [
			E('div', { 'class': 'ca-head', 'style': 'margin-bottom:2px' }, [ badge, E('strong', {}, it.title) ]),
			E('p', { 'class': 'ca-note' }, it.desc),
			it.warn ? E('p', { 'class': 'ca-note ca-warn' }, it.warn) : '',
			E('div', { 'class': 'ca-btnrow', 'style': 'margin-top:8px' }, btns)
		]);
	});

	startPolling();
	refreshAll();

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', { 'class': 'ca-title', 'style': 'margin-bottom:10px' }, _('出网特征体检与加固')),
		E('p', { 'class': 'ca-note', 'style': 'margin:0 0 8px' },
			_('这一页只做一件事：把“从校园网看过去，这台机器不像一台电脑”的地方逐条消掉。每一项都能单独应用、单独撤销。')),
		E('p', { 'class': 'ca-note ca-warn', 'style': 'margin:0 0 10px' },
			_('重要：一次只开一项，改完观察几天再动下一项。断线本来就不规律，一次全开的话，永远不知道是哪条起的作用。')),
		E('div', { 'class': 'ca-btnrow', 'style': 'margin:0 0 10px' }, [ btnHd ]),
		els.hdList,
		E('h4', { 'style': 'margin:16px 0 6px;font-size:13px' }, _('逐项加固')),
		E('div', { 'class': 'ca-tools' }, cards)
	]);
}

/* ------------------------------------------------------------------ 一键工具 */
function renderTools() {
	els.fwNote = E('div', { 'class': 'ca-env' }, _('检测中…'));
	els.pcNote = E('p', { 'class': 'ca-note' }, '');

	startPolling();
	refreshAll();

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', { 'class': 'ca-title', 'style': 'margin-bottom:10px' }, _('一键工具')),
		E('div', { 'class': 'ca-tools' }, [
			toolCard(_('防火墙规则'),
				_('DNS / NTP 强制走本机、统一 TTL 128；firewall3 还会屏蔽门户探测包。会自动判断 fw3 / fw4 并选对应写法。'),
				[
					toolButton(_('一键添加防火墙规则'), 'fwadd', 'apply', true),
					toolButton(_('一键移除规则'), 'fwdel'),
					toolButton(_('查看当前规则'), 'fwshow')
				]),
			toolCard(_('firewall4 专用（nftables）'),
				_('只操作 firewall4 那一份 nft 规则（写进 firewall.include）。上面的按钮已会自动判断，这里只是手动入口。'),
				[
					toolButton(_('添加 fw4 规则'), 'fwadd4', 'apply', true),
					toolButton(_('移除 fw4 规则'), 'fwdel4')
				]),
			toolCard(_('伪装成 Windows 电脑'), _('随机 LAPTOP-XXXXXXX 主机名、vendorid MSFT 5.0、client-id 跟随 MAC；UA 伪装建议继续用 ua3f。'),
				[
					toolButton(_('一键伪装 Windows PC'), 'pcfake', 'apply'),
					toolButton(_('恢复原始网络参数'), 'pcrestore')
				]),
			toolCard(_('依赖与诊断'), _('先检测防火墙版本与扩展是否齐全，缺什么装什么（需要已联网）。检测结果会显示在下面「当前环境」。'),
				[
					toolButton(_('检测缺失模块'), 'deps'),
					toolButton(_('安装缺失模块'), 'depinstall'),
					toolButton(_('重新生成 5 个 MAC'), 'genmac')
				]),
			toolCard(_('一键应用全部'), _('按当前环境自动加防火墙规则 + 伪装 PC + 应用 MAC 池，然后立刻检测一次外网。'),
				[
					toolButton(_('一键应用全部并检测'), 'applyall', 'apply')
				])
		]),
		E('h4', { 'style': 'margin:14px 0 4px;font-size:13px' }, _('当前环境')),
		els.fwNote,
		els.pcNote
	]);
}

/* ------------------------------------------------------------------ 运行日志 */
function renderLog() {
	els.log = E('pre', { 'class': 'ca-log' }, _('读取中…'));

	var btnRefresh = E('button', { 'class': 'cbi-button cbi-button-action' }, _('刷新'));
	var btnClear = E('button', { 'class': 'cbi-button cbi-button-reset' }, _('清空日志'));

	btnRefresh.addEventListener('click', function() {
		return refreshAll();
	});

	btnClear.addEventListener('click', function() {
		return fs.write(LOG_FILE, '').then(function() {
			notify(_('日志已清空'));
			return refreshAll();
		}).catch(function(err) {
			notify(_('清空失败：%s').format(err.message || err), 'warning');
		});
	});

	startPolling();
	refreshAll();

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', { 'class': 'ca-title', 'style': 'margin-bottom:10px' }, _('运行日志')),
		E('div', { 'class': 'ca-btnrow', 'style': 'margin:0 0 10px' }, [ btnRefresh, btnClear ]),
		els.log,
		E('p', { 'class': 'ca-note' }, _('日志同时写入系统日志，可用 logread -e likepc 查看。'))
	]);
}

/* ------------------------------------------------------------------ 页面 */
return view.extend({
	load: function() {
		return uci.load('likepc');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('likepc', _('模拟pc'),
			_('不含认证的校园网工具：检测外网、被拉黑时在预生成的 5 个 MAC 之间轮换、一键加防火墙规则、一键伪装 Windows 电脑。'));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.addremove = false;
		s.render = function() { return renderHero(); };

		s = m.section(form.NamedSection, 'main', 'likepc', _('检测设置'));
		s.tab('basic', _('基本设置'));
		s.tab('advanced', _('高级设置'));
		s.tab('mac', _('防拉黑 · 换 MAC'));

		o = s.taboption('basic', form.Flag, 'enabled', _('开机自动运行'),
			_('启用后路由器每次开机都会自动检测外网（并按开关处理）；关闭则什么都不做。'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'monitor', _('启用防掉线检测'),
			_('后台常驻检测外网，连续不通时按开关处理（换 MAC / 告警）；关闭则只在开机时检测一次。'));
		o.default = o.enabled;
		o.rmempty = false;


		o = s.taboption('basic', form.Value, 'ping_host', _('外网检测地址'),
			_('判断是否已经联网用，可填多个（空格或逗号分隔），任意一个能 ping 通即视为在线。'));
		o.default = '119.29.29.29';
		o.rmempty = false;


		o = s.taboption('advanced', form.Value, 'check_interval', _('掉线检测间隔（秒）'),
			_('防掉线检测每隔多少秒检查一次外网。'));
		o.datatype = 'uinteger';
		o.default = '30';
		o.rmempty = false;
		o.depends('monitor', '1');

		o = s.taboption('advanced', form.Value, 'fail_threshold', _('连续失败次数'),
			_('连续多少次检测不通后才开始处理（换 MAC / 告警），避免偶发丢包误判。'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.rmempty = false;
		o.depends('monitor', '1');

		o = s.taboption('advanced', form.Flag, 'alert_enable', _('连续检测失败时弹告警'),
			_('开启后，连续检测失败到设定次数时，本页顶部会出现红色告警横幅。'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'alert_threshold', _('失败几次后告警'),
			_('连续失败多少轮检测后开始告警；再翻三倍会升级成更醒目的“持续失败”。'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.rmempty = false;
		o.depends('alert_enable', '1');


		o = s.taboption('advanced', form.Value, 'start_delay', _('启动延迟（秒）'),
			_('开机后等待多久再开始检测，留给 WAN 口获取地址的时间。'));
		o.datatype = 'uinteger';
		o.default = '15';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'ping_count', _('ping 次数'));
		o.datatype = 'uinteger';
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'ping_timeout', _('ping 超时（秒）'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.rmempty = false;


		o = s.taboption('advanced', form.Flag, 'fw_probe_block', _('屏蔽门户探测地址（firewall4）'),
			_('局域网设备不许访问门户用来做多设备检测的地址。firewall3 用的是 iptables -m string 按正文丢包，nftables 没有字符串匹配，所以 fw4 改成按目标地址拦请求，效果一样而且不会误伤正常网页。'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'fw_probe_cidr', _('探测地址段'),
			_('门户注入的探测地址所在网段，可填多个用空格分隔。默认按你原来规则里的 src="http://1.1.1. 推出。'));
		o.default = '1.1.1.0/24';
		o.rmempty = true;
		o.depends('fw_probe_block', '1');

		/* ---- 防拉黑 · 换 MAC ---- */
		o = s.taboption('mac', form.Flag, 'mac_auto', _('启用防拉黑（外网不通自动换 MAC）'),
			_('开启后：检测到外网不通时自动在预先生成的 5 个 MAC 中轮换，最多换 mac_max_rotate 次、两次之间至少间隔 mac_cooldown 秒。'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('mac', form.Value, 'mac_oui', _('MAC 前缀池'),
			_('生成随机 MAC 用的厂商前缀，默认螃蟹网卡 00:e0:4c；可填多个用空格分隔（如 00:e0:4c 52:54:00）。'));
		o.default = '00:e0:4c';
		o.rmempty = true;

		o = s.taboption('mac', form.Value, 'mac_max_rotate', _('连续换几个 MAC 后停手'),
			_('一轮掉线最多连续轮换几次，避免一直换（默认 5，正好把 5 个用一遍）。'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.rmempty = false;

		o = s.taboption('mac', form.Value, 'mac_cooldown', _('轮换冷却（秒）'),
			_('两次自动换 MAC 之间的最小间隔，避免换得太频繁被交换机盯上。'));
		o.datatype = 'uinteger';
		o.default = '600';
		o.rmempty = false;

		o = s.taboption('mac', form.Value, 'mac_settle', _('换 MAC 后等待（秒）'),
			_('换完 MAC 后等 WAN 重新拿到地址再检测。'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.rmempty = false;

		o = s.taboption('mac', form.Value, 'wan_device', _('WAN 设备名'),
			_('默认自动识别（通过 ubus / 默认路由判断）；识别不准时手动填，例如 eth1。'));
		o.placeholder = _('自动');
		o.rmempty = true;

		o = s.taboption('mac', form.Value, 'wan_iface', _('WAN 接口名'),
			_('默认自动（一般是 wan），多 WAN 或改了接口名时手动填。'));
		o.placeholder = _('自动');
		o.rmempty = true;

		o = s.taboption('mac', form.Button, '_genmac', _('重新生成 MAC 池'), _('重新随机生成 5 个互不相同的 MAC。'));
		o.inputtitle = _('重新生成 5 个 MAC');
		o.inputstyle = 'apply';
		o.onclick = L.bind(function() {
			return runAction('genmac', _('已重新生成 5 个 MAC'));
		}, this);

		o = s.taboption('mac', form.Button, '_macnext', _('立即切换 MAC'), _('马上换成池中的下一个 MAC（首次会应用第一个）。'));
		o.inputtitle = _('立即切换到下一个 MAC');
		o.inputstyle = 'action';
		o.onclick = L.bind(function() {
			return runAction('macnext', _('已切换 WAN MAC'));
		}, this);

		o = s.taboption('mac', form.Button, '_macrestore', _('恢复原始 MAC'), _('删除本插件设置的 MAC，恢复路由器出厂 MAC。'));
		o.inputtitle = _('恢复 WAN 原始 MAC');
		o.inputstyle = 'reset';
		o.onclick = L.bind(function() {
			return runAction('macrestore', _('已恢复原始 MAC'));
		}, this);

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.addremove = false;
		s.render = function() { return renderHarden(); };

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.addremove = false;
		s.render = function() { return renderTools(); };

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.addremove = false;
		s.render = function() { return renderLog(); };

		return m.render();
	},

	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', [ ev, mode ]).then(function() {
			return execCmd(INIT_SCRIPT, [ 'restart' ]).then(function() {
				notify(_('设置已保存，服务已按新配置重启'));
			});
		});
	}
});