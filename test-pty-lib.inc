# Shared by tests that need a real terminal (sourced, not run).
# pty_install DIR ANSWERS... — runs "bash ${PTY_SCRIPT:-./install.sh} $PTY_ARGS" in DIR inside a
# pseudo terminal and sends one answer per pause in the output (Enter added).
# An answer "RAW:<python bytes literal body>" is sent as is, without Enter,
# e.g. RAW:\x1b[D for the left-arrow key, RAW:\x04 for Ctrl+D.
# The raw transcript is written to DIR/pty.raw, the colour-free one to DIR/pty.txt.
# PTY_ENV="NAME=value ..." adds environment variables.
pty_install() {
  local dir="$1"; shift
  ( cd "$dir" && env -u STY -u TMUX TERM=xterm ${PTY_ENV:-} python3 - "${PTY_ARGS:-}" "$@" <<'PY'
import os, pty, sys, time, select, ast
args = sys.argv[1].split() if sys.argv[1] else []
answers = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", os.environ.get("PTY_SCRIPT", "./install.sh")] + args)
out = b""; end = time.time() + 60; last = time.time()
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            b = os.read(fd, 4096)
        except OSError:
            break
        if not b:
            break
        out += b; last = time.time()
    elif answers and time.time() - last > 0.8:
        a = answers.pop(0)
        if a.startswith("RAW:"):
            data = ast.literal_eval("b'" + a[4:] + "'")
        else:
            data = (a + "\n").encode()
        os.write(fd, data); last = time.time()
    elif not answers and time.time() - last > 3:
        break
try:
    os.kill(pid, 9)
except OSError:
    pass
open("pty.raw", "wb").write(out)
PY
  ) || true
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$dir/pty.raw" | tr -d '\r' > "$dir/pty.txt"
}
