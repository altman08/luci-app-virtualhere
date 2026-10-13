'use strict';

import * as fs from 'fs';

// Execute the real RPC code with real temporary files and simulated UCI/procd.
let source = fs.readfile('luci-app-virtualhere/root/usr/share/rpcd/ucode/luci.virtualhere');
source = replace(source, /import [^\n]*;\n/g, '');
const create_rpc = loadstring('return function(fs, cursor, connect, system, sleep, clock) {\n' + source + '\n};', { raw_mode: true })();
let count = 0;

function expect(condition, message) {
	if (!condition) die(message);
}

function remove_tree(path) {
	if (fs.lstat(path)?.type == 'directory') {
		for (let name in fs.lsdir(path)) remove_tree(path + '/' + name);
		fs.rmdir(path);
	}
	else fs.unlink(path);
}

function fixture() {
	let dir = fs.mkdtemp('/tmp/virtualhere-rpc-test-XXXXXX');
	expect(dir, 'create test directory');
	let config = { enabled: '0', binary_path: dir + '/vhusbd', config_path: dir + '/server.conf' };
	fs.writefile(config.binary_path, '#!/bin/sh\nexit 0\n');
	fs.chmod(config.binary_path, 0700);
	fs.writefile(config.config_path, 'original');
	fs.chmod(config.config_path, 0640);
	let scenario = { dir, config, active: false, calls: [], milliseconds: 0, waits: [], stop_queries: 0 };
	let test_fs = {};
	for (let name, value in fs) test_fs[name] = value;
	test_fs.access = (path, mode) => {
		if (path == '/sbin/logread') return !scenario.log_fallback;
		return fs.access(path, mode);
	};
	test_fs.popen = (command, mode) => {
		let reader = scenario.log_fallback ? '/usr/sbin/logread' : '/sbin/logread';
		expect(index(command, 'exec ' + reader + ' ') == 0, 'must execute the fixed log reader');
		if (scenario.log_open_fail) return null;
		// OpenWrt logread uses BRE (REG_NOSUB, without REG_EXTENDED).
		// Keep that behavior here so an unescaped alternation cannot pass tests.
		fs.writefile(dir + '/system.log', scenario.log_output ?? '');
		fs.writefile(dir + '/logread', '#!/bin/sh\n' +
			'if [ "$#" -eq 0 ]; then\ncat "' + dir + '/system.log"\n' +
			'elif [ "$#" -eq 2 ] && [ "$1" = "-e" ]; then\ngrep "$2" "' + dir + '/system.log"\n' +
			'else\nexit 2\nfi\nexit ' + (scenario.log_exit ?? 0) + '\n');
		fs.chmod(dir + '/logread', 0700);
		return fs.popen(replace(command, reader, dir + '/logread'), mode);
	};
	test_fs.open = (path, mode, perm) => {
		if (path == '/var/lock/luci-virtualhere.lock') path = dir + '/lock';
		if (scenario.write_fail && match(path, /\/config.ini$/)) return null;
		return fs.open(path, mode, perm);
	};
	test_fs.mkdtemp = path => {
		if (scenario.during_write) scenario.during_write();
		return fs.mkdtemp(path);
	};
	let cursor = () => ({
		get: (package, section, key) => config[key],
		set: (package, section, key, value) => { if (key != 'virtualhere') config[key] = value; },
		delete: (package, section, key) => delete config[key],
		commit: () => true
	});
	let connect = () => ({
		call: () => {
			if (scenario.after_stop && scenario.cleanup_after != null && ++scenario.stop_queries > scenario.cleanup_after)
				scenario.active = false;
			return scenario.unavailable ? null : {
				vhusbd: { instances: scenario.active ? { main: { running: true, pid: 999999999 } } : {} }
			};
		},
		disconnect: () => null
	});
	let command = argv => {
		expect(argv[0] == '/etc/init.d/vhusbd', 'RPC waits must not invoke shell sleep');
		let action = argv[1];
		push(scenario.calls, action);
		if (action == 'stop_now') {
			if (scenario.stop_fail) return 1;
			scenario.after_stop = true;
			scenario.milliseconds += scenario.stop_elapsed ?? 0;
			if (!scenario.stuck && scenario.cleanup_after == null) scenario.active = false;
			if (scenario.on_stop) scenario.on_stop();
		}
		if (action == 'start_now') {
			if (scenario.start_fail) return 1;
			scenario.active = true;
		}
		return 0;
	};
	let pause = milliseconds => {
		push(scenario.waits, milliseconds);
		scenario.milliseconds += milliseconds;
	};
	let clock = monotonic => {
		expect(monotonic, 'stop deadline must use a monotonic clock');
		return [int(scenario.milliseconds / 1000), (scenario.milliseconds % 1000) * 1000000];
	};
	scenario.rpc = create_rpc(test_fs, cursor, connect, command, pause, clock)['luci.virtualhere'];
	scenario.write = apply => scenario.rpc.write_config.call({ args: {
		path: config.config_path, content: 'edited', original: 'original', exists: true, apply
	} });
	return scenario;
}

function test(name, callback) {
	let env = fixture();
	try {
		callback(env);
		printf('ok %d - %s\n', ++count, name);
	}
	catch (error) {
		remove_tree(env.dir);
		die('FAILED: ' + name + ': ' + error);
	}
	remove_tree(env.dir);
}

for (let enabled in ['0', '1']) {
	for (let active in [false, true]) {
		test('settings apply follows enabled=' + enabled + ', initially active=' + active, env => {
			env.active = active;
			let reply = env.rpc.save_settings.call({ args: {
				binary_path: env.config.binary_path, config_path: env.config.config_path, enabled, apply: true
			} });
			expect(reply.saved && !reply.error, 'settings should apply');
			expect(env.active == (enabled == '1'), 'runtime should follow enabled');
		});
	}
}

test('saving basic settings does not change the running service', env => {
	env.active = true;
	let reply = env.rpc.save_settings.call({ args: { ...env.config, apply: false } });
	expect(reply.saved && env.active, 'save should preserve running state');
	expect(length(env.calls) == 1 && env.calls[0] == 'enable', 'save should only maintain the boot entry');
});

test('manual service actions do not change enabled', env => {
	for (let action in ['start', 'restart', 'stop']) {
		let reply = env.rpc.action.call({ args: { action } });
		expect(reply.success, 'action should succeed');
		expect(env.config.enabled == '0', 'action should leave enabled off');
		expect(env.active == (action != 'stop'), 'action should change running state');
	}
});

test('ordinary file save rejects a managed instance before writing', env => {
	env.active = true;
	expect(env.write(false).error == 'stop_before_save', 'must stop before saving');
	expect(fs.readfile(env.config.config_path) == 'original', 'file must remain intact');
});

for (let enabled in ['0', '1']) {
	test('file apply follows enabled=' + enabled + ' and preserves permissions', env => {
		env.config.enabled = enabled;
		env.active = true;
		let reply = env.write(true);
		expect(reply.saved && !reply.error, 'file should be saved');
		expect(fs.readfile(env.config.config_path) == 'edited', 'new contents should be installed');
		expect((fs.stat(env.config.config_path).mode & 0777) == 0640, 'permissions should be preserved');
		expect(env.active == (enabled == '1'), 'runtime should follow enabled');
	});
}

test('stopping must remove the managed instance before writing', env => {
	env.active = true;
	env.stuck = true;
	expect(env.write(true).error == 'stop_failed', 'must reject an instance still managed by procd');
	expect(fs.readfile(env.config.config_path) == 'original', 'must not write');
});

test('stop waits for delayed procd instance removal after the PID disappears', env => {
	env.active = true;
	env.cleanup_after = 3;
	let reply = env.rpc.action.call({ args: { action: 'stop' } });
	expect(reply.success && !env.active, 'stop should succeed after delayed cleanup');
	expect(length(env.waits) == 3 && env.milliseconds == 300, 'must wait between status checks');
});

test('stop verification shares the init timeout instead of extending it', env => {
	env.active = true;
	env.stuck = true;
	env.stop_elapsed = 6000;
	let reply = env.rpc.action.call({ args: { action: 'stop' } });
	expect(reply.error == 'stop_failed', 'remaining instance must fail');
	expect(env.milliseconds == 8000, 'total stop budget must include init wait');
});

test('shutdown rewrites are detected and temporary service is restored', env => {
	env.active = true;
	env.on_stop = () => fs.writefile(env.config.config_path, 'shutdown rewrite');
	let reply = env.write(true);
	expect(reply.error == 'conflict', 'must report shutdown conflict');
	expect(fs.readfile(env.config.config_path) == 'shutdown rewrite', 'must preserve shutdown changes');
	expect(env.active && env.config.enabled == '0', 'must restore temporary service');
});

test('external writes while preparing replacement are detected', env => {
	env.during_write = () => fs.writefile(env.config.config_path, 'external change');
	let reply = env.write(false);
	expect(reply.error == 'conflict', 'must recheck contents before replacement');
	expect(fs.readfile(env.config.config_path) == 'external change', 'external edit must survive');
});

test('a retargeted symlink must not replace either target', env => {
	let original = env.config.config_path;
	let other = env.dir + '/other.conf';
	fs.writefile(other, 'original');
	env.config.config_path = env.dir + '/config-link';
	fs.symlink(original, env.config.config_path);
	env.during_write = () => {
		fs.unlink(env.config.config_path);
		fs.symlink(other, env.config.config_path);
	};
	expect(env.write(false).error == 'path_changed', 'must detect changed target even with identical contents');
	expect(fs.readfile(original) == 'original' && fs.readfile(other) == 'original', 'both targets must remain intact');
});

test('write failure and failed restoration are both reported', env => {
	env.active = true;
	env.write_fail = true;
	env.start_fail = true;
	let reply = env.write(true);
	expect(reply.error == 'write_failed', 'must preserve primary failure');
	expect(reply.restore_error == 'start_failed', 'must include recovery failure');
	expect(fs.readfile(env.config.config_path) == 'original', 'original file should remain intact');
});

test('successful write followed by failed start is reported as saved', env => {
	env.config.enabled = '1';
	env.start_fail = true;
	let reply = env.write(true);
	expect(reply.saved && reply.error == 'start_failed' && !reply.restore_error, 'must distinguish saved content from failed apply');
	expect(fs.readfile(env.config.config_path) == 'edited', 'new content should be kept');
});

test('transaction lock rejects concurrent mutations and is released afterwards', env => {
	let lock = fs.open(env.dir + '/lock', 'ae', 0600);
	expect(lock.lock('xn'), 'hold competing lock');
	let blocked = env.rpc.action.call({ args: { action: 'start' } });
	expect(blocked.error == 'lock_failed' && !length(env.calls), 'must not run commands while locked');
	lock.close();
	expect(env.rpc.action.call({ args: { action: 'start' } }).success, 'should work after lock is released');
});

test('logs include program, controller and related procd records while the service is stopped', env => {
	env.unavailable = true;
	env.log_output = join('\n', [
		'Tue Oct 13 10:43:43 2026 user.info vhusbd[1482]: Started',
		'Tue Oct 13 10:43:46 2026 user.notice virtualhere: stop failed',
		'Tue Oct 13 10:43:46 2026 daemon.info procd: vhusbd instance main stopped',
		'Tue Oct 13 10:43:46 2026 daemon.info procd: unrelated service stopped',
		'Tue Oct 13 10:43:49 2026 user.info vhusbd[1482]: >>> Shutdown <<<',
		'Tue Oct 13 10:43:49 2026 user.info dnsmasq[10]: unrelated', ''
	]);
	let reply = env.rpc.logs.call();
	expect(!reply.error && length(split(reply.content, '\n')) == 4, 'must return only matching records');
	expect(index(reply.content, 'virtualhere: stop failed') >= 0 && index(reply.content, '>>> Shutdown <<<') >= 0, 'both control and program messages must be retained');
	expect(!reply.truncated && !length(env.calls), 'logs do not query or change the service');
});

test('log line limits are applied after filtering and retain chronological order', env => {
	let lines = [];
	for (let i = 0; i < 250; i++) push(lines, 'vhusbd: record ' + i);
	for (let i = 0; i < 300; i++) push(lines, 'unrelated recent record ' + i);
	env.log_output = join('\n', lines) + '\n';
	let reply = env.rpc.logs.call();
	let recent = split(reply.content, '\n');
	expect(length(recent) == 200 && reply.truncated, 'must keep the last 200 matching records');
	expect(recent[0] == 'vhusbd: record 50' && recent[199] == 'vhusbd: record 249', 'newest record must remain last');
});

test('log byte limits discard a partial UTF-8 line and preserve the latest records', env => {
	let large = 'vhusbd: ';
	while (length(large) < 270000) large += '运行日志';
	env.log_output = large + '\nvhusbd: Shutdown\nvirtualhere: control error\n';
	let reply = env.rpc.logs.call();
	expect(reply.truncated && length(reply.content) <= 262144, 'output must be bounded');
	expect(reply.content == 'vhusbd: Shutdown\nvirtualhere: control error', 'partial first line must not corrupt later records');
});

test('unrelated logs larger than the byte budget do not displace matching records', env => {
	let lines = ['vhusbd: Started', 'virtualhere: control error'];
	for (let i = 0; i < 12000; i++) push(lines, 'dnsmasq: unrelated record ' + i);
	env.log_output = join('\n', lines) + '\n';
	let reply = env.rpc.logs.call();
	expect(!reply.error && !reply.truncated, 'only matching records count against the budget');
	expect(reply.content == 'vhusbd: Started\nvirtualhere: control error', 'older matching records must survive unrelated output');
});

test('log filtering preserves split keywords, UTF-8 and an unterminated last line', env => {
	let prefix = '';
	for (let i = 0; i < 4093; i++) prefix += 'x';
	env.log_output = prefix + 'vhusbd: 运行日志\nvirtualhere: final record';
	let reply = env.rpc.logs.call();
	expect(!reply.error && !reply.truncated, 'complete records must not be lost at chunk boundaries');
	expect(reply.content == env.log_output, 'keywords and UTF-8 must survive chunk boundaries and EOF');
});

test('no matching logs succeeds with empty content including the alternate logread path', env => {
	env.log_fallback = true;
	env.log_output = 'dnsmasq: unrelated\n';
	let reply = env.rpc.logs.call();
	expect(!reply.error && reply.content == '' && !reply.truncated, 'empty logs are a valid snapshot');
});

test('log reader launch and exit failures are errors even after partial output', env => {
	env.log_open_fail = true;
	expect(env.rpc.logs.call().error == 'logs_failed', 'launch failure must be reported');
	env.log_open_fail = false;
	env.log_output = 'vhusbd: incomplete snapshot\n';
	env.log_exit = 1;
	expect(env.rpc.logs.call().error == 'logs_failed', 'nonzero exit must not look like an empty or successful snapshot');
});

printf('Passed %d RPC tests\n', count);
