# SSH backend — manual integration checklist

Run against localhost (`System Settings → Sharing → Remote Login`, or any
reachable host in ~/.ssh/config). Re-run before tagging a release that touches
the SSH layer.

Setup: `ssh localhost true` works from a terminal without a password prompt
(key in agent) — or expect the native askpass dialog at step 2.

1. [ ] Source menu lists hosts from ~/.ssh/config and "New SSH Connection…".
2. [ ] Connect to localhost → spinner, then tree shows the home directory.
   (If the key needs a passphrase: native Lume — SSH dialog appears; Cancel
   surfaces "Can't Connect" with Retry.)
3. [ ] Expand a few directories — lazy loading, folders first, dotfiles hidden,
   `.env` visible, `node_modules`/`.git` absent, symlinks shown as leaves.
4. [ ] Go-to-path with a directory (e.g. `/tmp`) re-roots the tree; with a file
   (e.g. `/etc/hosts`) opens it in the editor.
5. [ ] Open a writable text file (`echo hi > ~/lume-ssh-test.md` first), edit,
   ⌘S → "Saving…" flashes; verify with `cat ~/lume-ssh-test.md` and `ls -l`
   (same permissions as before).
6. [ ] Set restrictive perms: `chmod 400 ~/lume-ssh-test.md`, edit, ⌘S →
   notice "Permission denied for …"; buffer stays dirty; `chmod 644`,
   ⌘S again → saves. No `.lume-tmp-*` litter in the directory.
7. [ ] Open a `.yaml`/`.env` file remotely → structured/env editor renders;
   edits save through ⌘S.
8. [ ] Open a binary (e.g. an image) remotely → "Text Only Over SSH" pane.
9. [ ] Recent files section shows the opened files (MRU, this host only).
10. [ ] Switch to Local mid-session → local tree intact; switch back → remote
    tree + connection still alive (no reconnect spinner).
11. [ ] Kill the master: `pkill -f 'ssh.*ControlMaster'`, then click a folder →
    one transparent reconnect (or askpass), listing succeeds.
12. [ ] Disconnect → back to Local; control socket gone from
    `~/Library/Application Support/Lume/ssh/`.
13. [ ] Quit + relaunch → saved manual connection still listed; per-host
    recents and last path survive.
14. [ ] Connect to an unreachable host (manual entry `10.255.255.1`) → clear
    "Can't Connect" with Retry/Disconnect within ~15 s (ConnectTimeout).
15. [ ] While the remote tree is showing, press ⌘⌫ / ⌘D → no local file-op
    fires (row selection was cleared on source switch).
