'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const test = require('node:test');

const source = readFileSync(resolve(__dirname,
	'../luci-app-virtualhere/htdocs/luci-static/resources/view/virtualhere/config.js'), 'utf8');
String.prototype.format = function(...args) {
	return this.replace(/%s/g, () => String(args.shift()));
};

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

function setup() {
	const calls = [];
	const settings = { enabled: '0', binary_path: '/usr/bin/vhusbd', config_path: '/etc/vhusbd.conf' };
	const status = { enabled: '0', running: false, pids: [] };
	const file = { path: settings.config_path, exists: true, content: 'original' };
	const replies = { settings, status, read_config: file, write_config: { saved: true }, action: { success: true }, logs: { content: 'vhusbd: started' } };
	const rpc = { declare: ({ method }) => (...args) => {
		calls.push({ method, args });
		return Promise.resolve().then(() => typeof replies[method] === 'function' ? replies[method](...args) : replies[method]);
	} };
	const E = (tag, attrs, children) => ({ tag, attrs, children });
	const L = { resolveDefault: (promise, fallback) => promise.catch(() => fallback) };
	const document = { hidden: false, getElementById: () => true };
	const view = new Function('view', 'rpc', 'dom', 'ui', 'L', 'E', '_', 'window', 'document', source)(
		{ extend: value => value }, rpc, { content: (node, value) => { node.content = value; } },
		{ addNotification() {} }, L, E, value => value, { confirm: () => true }, document);
	Object.assign(view, {
		settings, serviceStatus: status, statusRequest: 0, busy: false,
		map: { readonly: false, parse: () => Promise.resolve(), reset: () => { throw new Error('unexpected reset'); } },
		serviceButtons: Object.fromEntries(['start', 'stop', 'restart'].map(action => [action, { button: {}, style: action }])),
		fileButtons: { reload: {}, save: {}, apply: {} },
		file: { ...file }, editor: { value: 'edited' }, statusNode: {}, checkNode: { style: {} },
		filePath: {}, fileHint: {}, controlHint: {},
		options: Object.fromEntries(Object.keys(settings).map(key => [key, { formvalue: () => settings[key] }]))
	});
	view.updateButtons();
	return { view, calls, replies, status, file, document };
}

function logSetup() {
	const env = setup();
	const tab = { active: 'true', getAttribute() { return this.active; } };
	const classes = new Set();
	Object.assign(env.view, {
		logContent: null, logLoading: false, logRefresh: {},
		logHint: { classList: { add: name => classes.add(name), remove: name => classes.delete(name) } },
		logNode: { value: 'Logs have not been loaded.', isConnected: true, scrollTop: 0, clientHeight: 100, scrollHeight: 500, closest: () => tab }
	});
	return { ...env, tab, classes };
}

test('file reload excludes saves, service actions and reset until it completes', async () => {
	const { view, calls, replies, file } = setup();
	const pending = deferred();
	replies.read_config = pending.promise;
	const operation = view.reloadFile();
	assert.equal(view.editor.readOnly, true);
	assert.ok(Object.values(view.fileButtons).every(button => button.disabled));
	await Promise.all([view.saveFile(true), view.saveSettings(true), view.serviceAction('start'), view.handleReset(), view.reloadFile()]);
	assert.deepEqual(calls.map(call => call.method), ['read_config']);
	pending.resolve({ ...file, content: 'new file contents' });
	await operation;
	assert.equal(view.editor.value, 'new file contents');
	assert.equal(view.editor.readOnly, false);
	assert.equal(view.fileButtons.save.disabled, false);
});

test('pending saves suppress polling and stale replies without losing edits', async () => {
	const { view, calls, replies, status } = setup();
	const oldStatus = deferred();
	replies.status = oldStatus.promise;
	const oldRequest = view.refreshStatus();
	const write = deferred();
	replies.write_config = write.promise;
	const operation = view.saveFile(true);
	await view.refreshStatus();
	await view.reloadFile();
	oldStatus.resolve({ enabled: '1', running: true, pids: [123] });
	await oldRequest;
	assert.equal(view.serviceStatus, status);
	assert.equal(calls.filter(call => call.method === 'status').length, 1);
	assert.equal(calls.filter(call => call.method === 'read_config').length, 0);
	replies.status = { enabled: '0', running: false, pids: [] };
	write.resolve({ saved: true });
	await operation;
	assert.equal(view.editor.value, 'edited');
	assert.equal(view.file.content, 'edited');
	assert.equal(view.busy, false);
	assert.equal(calls.filter(call => call.method === 'status').length, 2);
});

test('service manager errors disable actions and do not show a successful file check', async () => {
	const { view, replies } = setup();
	replies.status = { error: 'service_unavailable' };
	await view.refreshStatus();
	assert.ok(Object.values(view.serviceButtons).every(item => item.button.disabled));
	assert.equal(view.checkNode.style.color, '');
	assert.match(view.checkNode.content, /Unable to query/);
	assert.equal(view.editor.value, 'edited');
});

test('initial status or file read failure still allows settings to load', async () => {
	const { view, replies } = setup();
	replies.status = replies.read_config = () => { throw new Error('offline'); };
	const result = await view.load();
	assert.equal(result[0].config_path, '/etc/vhusbd.conf');
	assert.equal(result[1].error, 'service_unavailable');
	assert.equal(result[2].error, 'read_failed');
});

test('a failed write reports both conflict and failed recovery, retaining edits', async () => {
	const { view, replies } = setup();
	replies.write_config = { error: 'conflict', restore_error: 'start_failed' };
	await assert.rejects(view.saveFile(true), error => /file changed/i.test(error.message) && /Restoring the previous service also failed/.test(error.message));
	assert.equal(view.editor.value, 'edited');
	assert.equal(view.file.content, 'original');
	assert.equal(view.busy, false);
	assert.equal(view.editor.readOnly, false);
});

test('failed reload preserves editor contents and releases the operation guard', async () => {
	const { view, replies } = setup();
	replies.read_config = () => { throw new Error('read failure'); };
	await assert.rejects(view.reloadFile(), /read failure/);
	assert.equal(view.editor.value, 'edited');
	assert.equal(view.busy, false);
	assert.equal(view.fileButtons.reload.disabled, false);
});

test('read-only accounts can reload but cannot write or control the service', async () => {
	const { view, calls } = setup();
	view.map.readonly = true;
	view.updateButtons();
	assert.equal(view.fileButtons.reload.disabled, false);
	assert.equal(view.fileButtons.save.disabled, true);
	assert.equal(view.fileButtons.apply.disabled, true);
	await Promise.all([view.saveFile(true), view.saveSettings(true), view.serviceAction('start')]);
	assert.equal(calls.length, 0);
});

test('logs are read only while their tab and the page are visible and no operation is pending', async () => {
	const { view, tab, document, calls } = logSetup();
	view.logNode.isConnected = false;
	await view.refreshLogs();
	view.logNode.isConnected = true;
	tab.active = 'false';
	await view.refreshLogs();
	tab.active = 'true';
	document.hidden = true;
	await view.refreshLogs();
	document.hidden = false;
	view.busy = true;
	await view.refreshLogs();
	assert.equal(calls.length, 0);
	view.busy = false;
	view.map.readonly = true;
	await view.refreshLogs();
	assert.deepEqual(calls.map(call => call.method), ['logs']);
	assert.equal(view.logRefresh.disabled, false);
	assert.equal(view.editor.value, 'edited');
	assert.equal(view.serviceStatus.running, false);
});

test('concurrent log refreshes do not duplicate the pending read or lose edits', async () => {
	const { view, replies, calls } = logSetup();
	const pending = deferred();
	replies.logs = pending.promise;
	const refresh = view.refreshLogs();
	assert.equal(view.logRefresh.disabled, true);
	await view.refreshLogs();
	pending.resolve({ content: 'vhusbd: stopped' });
	await refresh;
	assert.equal(calls.length, 1);
	assert.equal(view.logNode.value, 'vhusbd: stopped');
	assert.equal(view.editor.value, 'edited');
	assert.equal(view.logLoading, false);
});

test('logs follow the bottom on first load and retain the scroll position when reading older entries', async () => {
	const { view, replies } = logSetup();
	await view.refreshLogs();
	assert.equal(view.logNode.scrollTop, 500);
	view.logNode.scrollTop = 120;
	replies.logs = { content: 'vhusbd: next line' };
	await view.refreshLogs();
	assert.equal(view.logNode.scrollTop, 120);
	view.logNode.scrollTop = 400;
	replies.logs = { content: 'vhusbd: last line' };
	await view.refreshLogs();
	assert.equal(view.logNode.scrollTop, 500);
});

test('unchanged logs are not replaced and markup is displayed as plain text', async () => {
	const { view, replies } = logSetup();
	const content = 'vhusbd: <img src=x onerror=alert(1)>';
	replies.logs = { content };
	await view.refreshLogs();
	assert.equal(view.logNode.value, content);
	Object.defineProperty(view.logNode, 'value', { set() { throw new Error('unexpected replacement'); } });
	await view.refreshLogs();
	assert.equal(view.logHint.textContent, '');
});

test('empty logs and read errors are distinct, and failures preserve the last snapshot', async () => {
	const { view, replies, classes } = logSetup();
	replies.logs = { content: '' };
	await view.refreshLogs();
	assert.equal(view.logNode.value, 'No VirtualHere log entries.');
	replies.logs = { content: 'virtualhere: stop failed', truncated: true };
	await view.refreshLogs();
	assert.match(view.logHint.textContent, /most recent/);
	for (const failure of [{ error: 'logs_failed' }, {}, () => { throw new Error('RPC offline'); }]) {
		replies.logs = failure;
		await view.refreshLogs();
		assert.equal(view.logNode.value, 'virtualhere: stop failed');
		assert.equal(view.logHint.textContent, 'Unable to read the runtime log.');
		assert.ok(classes.has('warning'));
		assert.equal(view.logRefresh.disabled, false);
	}
	replies.logs = { content: 'vhusbd: recovered' };
	await view.refreshLogs();
	assert.equal(view.logHint.textContent, '');
	assert.equal(classes.has('warning'), false);
});

test('stopping refreshes visible logs after the action finishes', async () => {
	const { view, calls, replies } = logSetup();
	view.serviceStatus = { enabled: '1', running: true, pids: [123] };
	view.updateButtons();
	replies.logs = { content: 'vhusbd: Shutdown' };
	await view.serviceAction('stop');
	assert.deepEqual(calls.map(call => call.method), ['action', 'status', 'logs']);
	assert.equal(view.logNode.value, 'vhusbd: Shutdown');
	assert.equal(view.serviceStatus.running, false);
	assert.equal(view.editor.value, 'edited');
});

for (const failure of [false, true]) {
	test(`stop shows an exit wait hint and clears it after ${failure ? 'failure' : 'success'}`, async () => {
		const { view, replies, calls } = setup();
		const running = { enabled: '1', running: true, pids: [123] };
		view.serviceStatus = running;
		view.updateButtons();
		const pending = deferred();
		replies.action = pending.promise;
		replies.status = failure ? running : { enabled: '1', running: false, pids: [] };
		const operation = view.serviceAction('stop');
		assert.equal(view.controlHint.content, 'Stopping VirtualHere; waiting for the process to exit…');
		assert.equal(view.serviceStatus.running, true);
		assert.ok(Object.values(view.serviceButtons).every(item => item.button.disabled));
		await view.serviceAction('stop');
		assert.equal(calls.filter(call => call.method === 'action').length, 1);
		pending.resolve(failure ? { error: 'stop_failed' } : { success: true });
		if (failure)
			await assert.rejects(operation, /stop the service completely/i);
		else
			await operation;
		assert.equal(view.busy, false);
		assert.equal(view.pendingAction, null);
		assert.doesNotMatch(view.controlHint.content, /waiting for the process/);
		assert.equal(view.serviceStatus.running, failure);
		assert.equal(view.serviceButtons.stop.button.disabled, !failure);
	});
}

test('switching tabs during a read preserves the previous log and scroll position until reopening', async () => {
	const { view, replies, tab } = logSetup();
	await view.refreshLogs();
	view.logNode.scrollTop = 120;
	const previous = view.logNode.value;
	const pending = deferred();
	replies.logs = pending.promise;
	const refresh = view.refreshLogs();
	tab.active = 'false';
	view.logNode.clientHeight = view.logNode.scrollHeight = 0;
	pending.resolve({ content: 'vhusbd: new entry' });
	await refresh;
	assert.equal(view.logNode.value, previous);
	assert.equal(view.logNode.scrollTop, 120);
	tab.active = 'true';
	view.logNode.clientHeight = 100;
	view.logNode.scrollHeight = 500;
	await view.refreshLogs();
	assert.equal(view.logNode.value, 'vhusbd: new entry');
	assert.equal(view.logNode.scrollTop, 120);
});
