# All-Encompassing Favorites — Manual Test Checklist

Prereqs: one SSH host you can reach (or the localhost setup from
`docs/ssh-manual-test-checklist.md`) and one GitHub repo (`gh` signed in).

## Pin
1. [ ] Connect to an SSH host, right-click a remote file → "Add to Favorites".
2. [ ] Right-click a remote folder → "Add to Favorites".
3. [ ] Open a GitHub repo, right-click a file → "Add to Favorites".

## Merged list
4. [ ] Switch the source switcher to Local. The Favorites section shows the
       local favorites AND the SSH file/folder (⚡ + alias badge) AND the GitHub
       file (branch icon + slug badge), all in one list.
5. [ ] Each remote favorite shows the filename + its source badge + a pin glyph.

## Open from disconnected
6. [ ] From Local, click the SSH file favorite → connects to the host and opens
       the file in the editor.
7. [ ] Click the SSH folder favorite → connects and the remote tree reroots to
       that folder.
8. [ ] Click the GitHub favorite → connects to the repo (default/last branch)
       and opens the file.

## Unpin
9. [ ] Right-click a remote favorite → "Remove from Favorites"; it disappears.
10. [ ] Re-pin, then right-click the same item in the remote tree → the menu now
        reads "Remove from Favorites" (state reflects the pin).

## Stale source
11. [ ] Pin an SSH file, then make the host unreachable (e.g. wrong alias /
        stopped sshd). Click the favorite → a connect error shows in the header;
        the favorite STAYS in the list.
12. [ ] Pin a GitHub file, rename/delete the repo on github.com, click the
        favorite → "Repository not found"; the favorite stays.

## Persistence / migration
13. [ ] Quit and relaunch Lume → all favorites (local + remote) are still there.
14. [ ] (If testing an upgrade) launch over a pre-existing library → old local
        favorites are intact and remote pinning works (V1→V2 migration).
