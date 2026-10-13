"""Exercise the actual init stop function with real, delayed-exit processes."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest


INIT = Path(__file__).resolve().parents[1] / 'luci-app-virtualhere/root/etc/init.d/vhusbd'
CHILD = '''
import signal, sys, time
def stop(*args):
    time.sleep(float(sys.argv[1]))
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print('ready', flush=True)
while True:
    signal.pause()
'''

HARNESS = r'''
. "$1"
logger() { :; }
ubus() {
    if [ "$VH_TEST_MODE" = absent ]; then
        printf '{}\n'
    else
        printf '{"vhusbd":{"instances":{"main":{"running":true,"pid":%s}}}}\n' "$VH_TEST_PID"
    fi
}
jsonfilter() { cat >/dev/null; printf '%s\n' "$VH_TEST_PID"; }
stop() {
    [ "$VH_TEST_MODE" = ignore ] || kill -TERM "$VH_TEST_PID"
}
sleep() {
    printf '%s\n' "$1" >> "$VH_TEST_SLEEPS"
    case "$1" in
        *[!0-9]*) printf 'sleep: invalid integer: %s\n' "$1" >&2; return 1 ;;
    esac
    /bin/sleep "$1"
}
stop_now
'''


class StopTests(unittest.TestCase):
    def run_stop(self, delay=0, mode='normal'):
        child = None
        reaper = None
        try:
            if mode != 'absent':
                child = subprocess.Popen([sys.executable, '-c', CHILD, str(delay)],
                                         stdout=subprocess.PIPE, universal_newlines=True)
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                reaper = threading.Thread(target=child.wait)
                reaper.start()
            with tempfile.TemporaryDirectory(prefix='virtualhere-init-test-') as directory:
                sleeps = Path(directory) / 'sleeps'
                env = dict(os.environ, VH_TEST_MODE=mode, VH_TEST_SLEEPS=str(sleeps),
                           VH_TEST_PID=str(child.pid) if child else '')
                started = time.monotonic()
                result = subprocess.run(['/bin/sh', '-c', HARNESS, 'test', str(INIT)],
                                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        universal_newlines=True, timeout=12)
                elapsed = time.monotonic() - started
                waits = sleeps.read_text().splitlines() if sleeps.exists() else []
            return result, elapsed, waits
        finally:
            if child:
                if child.poll() is None:
                    child.kill()
                reaper.join(timeout=3)
                child.stdout.close()

    def test_delayed_shutdown_with_integer_only_sleep(self):
        result, elapsed, waits = self.run_stop(delay=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 2)
        self.assertTrue(waits)
        self.assertTrue(all(value == '1' for value in waits), waits)

    def test_absent_service_succeeds_without_waiting(self):
        result, elapsed, waits = self.run_stop(mode='absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(waits, [])

    def test_process_exiting_during_last_wait_is_checked(self):
        result, elapsed, waits = self.run_stop(delay=5.3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 5.3)

    def test_process_that_does_not_exit_is_not_reported_stopped(self):
        result, elapsed, waits = self.run_stop(mode='ignore')
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 6)
        self.assertIn('Unable to stop VirtualHere completely', result.stderr)


if __name__ == '__main__':
    unittest.main()
