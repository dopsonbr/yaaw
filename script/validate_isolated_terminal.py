#!/usr/bin/env python3
"""Headless end-to-end validation of the out-of-process agent terminal helper.

Drives the real YAAWToolHost binary over the same stdin/stdout JSON IPC the
parent app uses, exercising the per-terminal process-isolation guarantees
without a GUI:

  A. Lifecycle      launch -> ready -> forkpty agent runs -> output tee'd to the
                    capture log -> exit code propagated -> clean shutdown.
  B. Flood isolation a runaway agent's high-volume output goes to the capture log
                    on disk, NOT across the IPC channel to the parent (the parent
                    only ever receives small control events). This is why a
                    flooding/hung terminal can't wedge the main app.
  C. Independent kill SIGKILLing one helper leaves a sibling helper running.

Run: python3 script/validate_isolated_terminal.py
"""
import json, subprocess, sys, os, time, tempfile, threading, signal

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def helper_path():
    binpath = subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=REPO).decode().strip()
    return os.path.join(binpath, "YAAWToolHost")


class Helper:
    """Drives one YAAWToolHost terminal instance over IPC."""

    def __init__(self, binary, instance):
        self.instance = instance
        self.proc = subprocess.Popen(
            [binary, "--tool-kind", "terminal", "--instance-id", instance],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.events = []
        self.stdout_bytes = 0
        self.stderr = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.proc.stdout:
            self.stdout_bytes += len(line)
            s = line.decode(errors="replace").strip()
            if not s:
                continue
            try:
                self.events.append(json.loads(s))
            except Exception:
                self.events.append({"type": "?raw", "raw": s[:120]})

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line.decode(errors="replace"))

    def _envelope(self, typ, payload):
        return json.dumps({
            "protocolVersion": 2, "toolKind": "terminal", "instanceID": self.instance,
            "messageID": "m", "type": typ, "payload": payload})

    def send(self, typ, payload={}):
        if self.proc.poll() is not None:
            return
        try:
            self.proc.stdin.write((self._envelope(typ, payload) + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def launch(self, command, capture_path, working_dir="/tmp", env=None):
        self.send("launchTerminal", {
            "command": json.dumps(command),
            "environment": json.dumps(env or {"TERM": "xterm-256color"}),
            "workingDirectory": working_dir,
            "captureLogPath": capture_path,
        })

    def start_surface(self):
        # Offscreen so nothing flashes on screen; still inits the surface, which
        # is what triggers the forkpty process to start.
        self.send("setViewport", {
            "x": "-30000", "y": "-30000", "width": "600", "height": "400", "visible": "true"})

    def wait_for(self, typ, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if any(e.get("type") == typ for e in self.events):
                return True
            if self.proc.poll() is not None:
                return False
            time.sleep(0.03)
        return False

    def has(self, typ):
        return any(e.get("type") == typ for e in self.events)

    def event(self, typ):
        return next((e for e in self.events if e.get("type") == typ), None)

    def alive(self):
        return self.proc.poll() is None

    def shutdown(self):
        self.send("shutdown")

    def kill(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def tmp_capture(name):
    p = os.path.join(tempfile.gettempdir(), "yaaw_val_%s_%d.log" % (name, os.getpid()))
    if os.path.exists(p):
        os.remove(p)
    return p


def read_file(path):
    if not os.path.exists(path):
        return ""
    with open(path, errors="replace") as f:
        return f.read()


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print("  [%s] %s%s" % ("PASS" if ok else "FAIL", name, (" — " + detail) if detail else ""))


def scenario_lifecycle(binary):
    print("\nA. Lifecycle + capture-log tee + exit code")
    cap = tmp_capture("life")
    marker = "ISO_LIFECYCLE_OK_4242"
    h = Helper(binary, "val-life")
    h.launch(["/bin/sh", "-lc", "printf '%%s\\n' %s; sleep 0.2; exit 7" % marker], cap)
    ready = h.wait_for("ready", 8)
    h.start_surface()
    exited = h.wait_for("exited", 12)
    time.sleep(0.3)
    cap_text = read_file(cap)
    ev = h.event("exited") or {}
    check("helper became ready", ready)
    check("agent output tee'd to capture log", marker in cap_text,
          "%d bytes" % len(cap_text))
    check("exit event received", exited)
    check("exit code propagated (7)", ev.get("payload", {}).get("exitCode") == "7",
          repr(ev.get("payload")))
    alive = h.alive()
    h.shutdown()
    time.sleep(0.5)
    check("helper stays alive after agent exit", alive)
    check("helper exits cleanly on shutdown", not h.alive())
    if h.stderr:
        print("   stderr:", "".join(h.stderr)[:400])
    h.kill()


def scenario_flood(binary):
    print("\nB. Flood isolation (output to disk, not across IPC)")
    cap = tmp_capture("flood")
    # ~3 MB of output as fast as the PTY allows.
    h = Helper(binary, "val-flood")
    h.launch(["/bin/sh", "-lc", "head -c 3000000 /dev/zero | tr '\\0' 'A'; exit 0"], cap)
    ready = h.wait_for("ready", 8)
    h.start_surface()
    exited = h.wait_for("exited", 20)
    time.sleep(0.5)
    cap_text = read_file(cap)
    check("helper became ready", ready)
    check("capture log captured the flood (>500 KB)", len(cap_text) > 500_000,
          "%d bytes" % len(cap_text))
    # The parent's IPC channel must stay tiny — only control events, never output.
    check("IPC stdout stayed small (<64 KB) despite the flood", h.stdout_bytes < 64_000,
          "%d bytes over IPC" % h.stdout_bytes)
    check("flooding helper did not crash (clean exit event)", exited)
    h.shutdown()
    time.sleep(0.5)
    check("flooding helper exits cleanly", not h.alive())
    if h.stderr:
        print("   stderr:", "".join(h.stderr)[:400])
    h.kill()


def scenario_exec_env_inheritance(binary):
    print("\nD. Plain exec terminal inherits a usable environment")
    cap = tmp_capture("exec")
    marker = "PATHSEEN"
    # Empty environment in the launch -> helper must inherit its own env so the
    # shell has a real PATH (this is how bottom/nvim/lazygit terminals launch).
    h = Helper(binary, "val-exec")
    h.send("launchTerminal", {
        "command": json.dumps(
            ["/bin/sh", "-lc", "[ -n \"$PATH\" ] && printf '%s\\n' " + marker + "; exit 0"]),
        "environment": json.dumps({}),  # empty -> inherit
        "workingDirectory": "/tmp",
        "captureLogPath": cap,
    })
    ready = h.wait_for("ready", 8)
    h.start_surface()
    h.wait_for("exited", 12)
    time.sleep(0.3)
    cap_text = read_file(cap)
    check("exec helper ready", ready)
    check("inherited env gave the shell a PATH", marker in cap_text, "%d bytes" % len(cap_text))
    h.shutdown()
    time.sleep(0.4)
    check("exec helper exits cleanly", not h.alive())
    h.kill()


def scenario_independent_kill(binary):
    print("\nC. Independent kill (one helper down, sibling unaffected)")
    cap_a, cap_b = tmp_capture("killA"), tmp_capture("killB")
    a = Helper(binary, "val-killA")
    b = Helper(binary, "val-killB")
    a.launch(["/bin/sh", "-lc", "sleep 30"], cap_a)
    b.launch(["/bin/sh", "-lc", "sleep 30"], cap_b)
    ra = a.wait_for("ready", 8)
    rb = b.wait_for("ready", 8)
    a.start_surface()
    b.start_surface()
    time.sleep(0.5)
    check("both sibling helpers ready", ra and rb)
    check("both helpers alive", a.alive() and b.alive())
    # Hard-kill A (simulating a crash / forced kill of one terminal).
    a.kill()
    time.sleep(0.8)
    check("killed helper A is gone", not a.alive())
    check("sibling helper B unaffected (still running)", b.alive())
    b.shutdown()
    time.sleep(0.5)
    check("helper B exits cleanly on its own shutdown", not b.alive())
    b.kill()


def main():
    print("building YAAWToolHost...")
    subprocess.check_call(["swift", "build"], cwd=REPO,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    binary = helper_path()
    print("helper:", binary)
    scenario_lifecycle(binary)
    scenario_flood(binary)
    scenario_exec_env_inheritance(binary)
    scenario_independent_kill(binary)
    passed = sum(1 for r in results if r)
    print("\n==== %d/%d checks passed ====" % (passed, len(results)))
    print("RESULT:", "PASS" if all(results) else "FAIL")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
