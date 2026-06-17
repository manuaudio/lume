# Favorites Sync — Manual Test Checklist (two Macs)

Prereqs: two Macs signed into the same Apple ID with iCloud Drive on, both
running a Lume build signed with a Developer Team that has the
`iCloud.com.lume.Lume` container enabled (the repo's ad-hoc dev build will
NOT sync — `isAvailable` is false there).

## Favorites
1. [ ] On Mac A, pin an SSH remote file. Within a minute it appears in Mac B's
       Favorites (badge + filename).
2. [ ] On Mac A, pin a GitHub file → appears on Mac B.
3. [ ] On Mac A, unpin one → it disappears on Mac B (tombstone propagates).

## Manual connections
4. [ ] On Mac A, add a New SSH Connection (manual host). On Mac B the host
       appears in the source switcher's Saved Connections, and connecting works
       (assuming the key/agent is set up on B).
5. [ ] Confirm the private key file itself was NOT copied — only the path.
       A host whose `~/.ssh` key is absent on B fails auth (expected).

## Conflict / offline
6. [ ] Turn off Wi-Fi on both. Pin different favorites on each. Reconnect →
       both favorites end up on both Macs (concurrent adds both survive).
7. [ ] Offline, unpin the same favorite on A and edit nothing on B. Reconnect →
       it's gone on both (delete wins / propagates).

## Availability
8. [ ] Sign out of iCloud on Mac B → Lume still works; favorites just stop
       syncing (no errors, no dead-ends). Sign back in → sync resumes.
