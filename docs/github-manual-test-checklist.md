# GitHub Backend — Manual Integration Checklist

Prereqs: `gh` installed and signed in (`gh auth status` green); one repo you
can push to (ideally with a second branch), one read-only repo (any public
repo you don't own).

## Auth & connect
1. [ ] With gh signed out (`gh auth logout`): Open GitHub Repo… → connect fails
       with the "gh auth login" message. Sign back in; Retry succeeds.
2. [ ] Open GitHub Repo… with `owner/repo` slug → tree appears at `/` on the
       default branch; branch chip shows it.
3. [ ] Open GitHub Repo… with a pasted `https://github.com/owner/repo` URL →
       same result.
4. [ ] Browse Your Repos… → list loads, filter narrows it, private repos show
       a lock; picking one connects.
5. [ ] Open a nonexistent repo (`owner/nope`) → "Repository not found" in the
       header with Retry.

## Browse & edit
6. [ ] Expand folders lazily; `.git`-style noise hidden; `.env` visible.
7. [ ] Go-to-path with `/docs` re-roots; with `/README.md` opens the file.
8. [ ] Open a Markdown file → editor renders; edit → dirty dot; ⌘S → saving
       indicator, then a new commit "Update README.md" appears on GitHub on
       the active branch.
9. [ ] Save again without re-opening → second commit lands (sha chain works).
10. [ ] Recent files list grows; clicking a recent re-opens it.

## Branches
11. [ ] Switch branches via the chip → tree re-roots, open file closes;
        editing + ⌘S commits to the new branch. Reconnecting later lands on
        the last-used branch.

## Conflicts & permissions
12. [ ] Open a file, edit it on github.com, then ⌘S in Lume → conflict dialog;
        Keep Editing leaves the buffer dirty; ⌘S again → dialog again;
        Reload fetches the remote version; a subsequent edit + ⌘S commits.
13. [ ] Open the read-only repo → Read-only badge appears; ⌘S on an edit →
        "You don't have push access" notice and the buffer stays dirty.

## Edge cases
14. [ ] A file >1 MB opens (blob fallback).
15. [ ] A binary file (image) shows the unsupported pane, not garbage.
16. [ ] Switch to Local and back → GitHub tree state is preserved;
        Disconnect → switcher returns to Local; repo appears under recents.
