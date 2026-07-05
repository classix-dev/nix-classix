# matrix-discord-relay hardening backlog

Notes on locking the relay box down against abuse from unknown IPs. None
of this is urgent and most of it should wait until the bridge is actually
relaying, for reasons noted per item. The module itself is
[default.nix](default.nix).

## Framing

The box has two public surfaces that need opposite treatment.

Federation cannot be IP-restricted. Matrix federation is open by design,
any homeserver might legitimately need to reach ours (matrix.org, plus
every other server with a user in the bridged room), and that list is not
knowable in advance. So `/_matrix/federation/*` and `/_matrix/key/*` have
to accept connections from anywhere.

The client API does not need to be public at all. Nobody holds an account
on this server. The operators are on matrix.org and the bridge talks to
Synapse over loopback (127.0.0.1:8008), never through 443. So the entire
`/_matrix/client/*` surface can be closed to the internet.

## Already in place

- Federation requests are signature-authenticated. Synapse rejects
  unsigned or forged requests cheaply, before doing real work.
- Synapse ships per-server federation rate limiting (`rc_federation`) and
  a default SSRF IP blacklist on outbound federation.
- Hetzner Cloud includes automatic network-level DDoS protection at no
  cost, which absorbs volumetric floods.
- Registration is disabled and SSH is key-only.

## Backlog, highest value first

### 1. Split the Caddy routing, close the client API externally

Today Caddy sends all of `/_matrix/*` to Synapse, which includes the login
and account endpoints under `/_matrix/client/*`. Expose only what must be
public: `/_matrix/federation`, `/_matrix/key`, the federation media
endpoints, `/.well-known/matrix/server`, and the `/mautrix-discord` avatar
proxy. Everything else, including `/_matrix/client`, returns 404 at the
edge.

This is the biggest surface reduction and has no downside here, because
there are no local clients. Do it once relaying is confirmed stable, not
before, so an over-tight rule cannot break the initial join and plumbing.

### 2. fail2ban on the box

Ban IPs that generate repeated auth failures or garbage, as defense in
depth on top of Synapse's own rejection. Cheap, safe to add alongside #1.

### 3. Tune Synapse rate limits after observing real traffic

`rc_federation`, `rc_joins`, `rc_invites` bound how much any single remote
server can push. Set these once we have watched roughly a week of normal
levels, so we do not clip legitimate bursts. Needs real traffic first.

### 4. federation_domain_whitelist (maybe, with a real tradeoff)

Synapse can refuse federation from every server except an allowlist.
Locking it to matrix.org alone would make the server ignore all other
homeservers.

The catch: the bridged room has members on other homeservers too, and in
Matrix a server exchanges events directly with every server that has a
member in the room, not just the room's host. A matrix.org-only whitelist
would silently drop messages from anyone in the room who is not on
matrix.org. This one needs data. Once relaying, look at which servers
actually appear in the room membership, then decide whether a whitelist is
safe or too lossy.

## SSH (independent of the Matrix surface)

Port 22 is key-only, which is the main thing. To go further, restrict it
to known operator IPs or put it behind fail2ban.

## Why wait until relaying

Two reasons. Over-restricting during setup can break the first federated
join and the room plumbing. And items #3 and #4 are decisions that can
only be made well with real traffic and real room membership in front of
us.
