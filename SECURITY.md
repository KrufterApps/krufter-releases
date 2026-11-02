# Security policy

Krufter is a desktop Kubernetes client that handles kubeconfigs, SSH credentials
and cluster data. We take reports about it seriously and we want to hear about
problems before anyone else does.

What the product does with your data, and the result of our latest review, are
published at **https://krufter.dev/security**. This file is the disclosure
policy.

## Where credentials are stored

SSH passwords and the sign-in session token (the Firebase refresh token) are
kept in the operating system keyring (Secret Service, Keychain or Credential
Manager), never in a plain file. If no keyring is available, Krufter does not
fall back to a file: the session simply does not survive a restart.

## Supported versions

Krufter ships a single release channel (Linux, macOS, Windows) through the
public release mirror <https://github.com/KrufterApps/krufter-releases> and the
in-app updater. **Only the latest published release is supported**: security
fixes are published as a new release, older versions are not patched. If you
report an issue, please check that it reproduces on the latest release.

| Version                   | Supported |
|---------------------------|-----------|
| Latest published release  | yes       |
| Anything older            | no, update |

The krufter.dev site and the Firebase backend (Cloud Functions, Firestore rules)
are deployed continuously: only what is live is supported.

## Auto-update integrity

The in-app updater does not trust the release mirror, only a GPG key shipped
inside the application:

* **The manifest is signed.** The release pipeline signs `latest.json` with the
  Krufter release key (`Krufter <admin@krufter.dev>`, key id `3CB644EB146CEAD1`,
  fingerprint `20D3 FF90 D31C B1BF 8944  2E30 3CB6 44EB 146C EAD1`, also on
  <https://keys.openpgp.org>) and publishes the detached signature
  `latest.json.asc` next to it, before the manifest itself. The release job
  fails if the key is missing or the signature cannot be produced.
* **The client verifies it before anything else.** Before it believes
  `latest.json`, the application checks `latest.json.asc` against the public key
  embedded in the app (pure-Dart OpenPGP, same code on Linux, Windows and
  macOS). A missing signature, a signature that does not match the manifest
  bytes, or one made by any other key means the update is reported as
  unavailable and **nothing is downloaded**. Write access to the mirror alone
  is therefore not enough to push an installer.
* **The installer is checked too.** The downloaded file must match the SHA-256
  published in the signed manifest, otherwise it is deleted.
* **Allowed download hosts.** An installer URL must be `https` and its host must
  be exactly `github.com`, `objects.githubusercontent.com` or
  `release-assets.githubusercontent.com`. This is enforced when the manifest is
  read and again at every redirect while downloading; anything else is refused.

Not covered yet: the Windows installers are not Authenticode-signed and the
macOS app is not notarised, so the operating system shows its usual
unknown-publisher warnings. The embedded key expires on 2028-10-20; it will be
extended or rotated, with a new key shipped in a release, before then.

## Reporting a vulnerability

Email **admin@krufter.dev**.

Please do **not** open a public issue, discussion or pull request for a
vulnerability, and do not post details publicly before we have fixed it.

Useful information: what you found and why it matters, the version or URL, the
steps to reproduce (or a proof of concept), and whether you want to be credited.
You do not need a working exploit: a clear description is enough to start.

If you need an encrypted channel, say so in a first message without technical
details and we will set one up.

## What to expect

| Step                                             | Target                                   |
|--------------------------------------------------|------------------------------------------|
| Acknowledgement of your report                   | within **72 hours**                      |
| First assessment (severity, affected versions)   | within 7 days                            |
| Fix published, by severity                       | critical **7 days**, high **30 days**, medium **90 days**, low: next planned release |
| Disclosure                                       | coordinated with you, at the latest 90 days after the report |

These are targets, not guarantees: Krufter is built by a small team. If we
cannot meet one, we will tell you why and agree a new date with you.

Severity follows impact on users' clusters, credentials and accounts
(critical / high / medium / low). Reporters who ask for it are credited in the
release notes; anonymous reports are welcome.

## Scope

In scope:

* the Krufter desktop application (Rust core and Flutter UI), its installers and
  the update mechanism;
* the Firebase backend operated by Krufter: Cloud Functions (including the AI
  proxy `aiChat`), Firestore security rules, the admin console;
* the krufter.dev site and the release pipeline / mirror.

Out of scope:

* vulnerabilities of third-party services (Firebase, Google Cloud, Stripe,
  GitHub): please report them to the vendor;
* attacks that need a device or an account already fully compromised, or that
  rely on social engineering of Krufter staff or users;
* volumetric denial of service, automated scanner output without a demonstrated
  impact, missing hardening headers without a concrete attack, reports about
  software that is not Krufter;
* the security of your own clusters (RBAC, network policies): Krufter uses the
  credentials you give it, with the rights those credentials have.

## Known limitations

**No App Check enforcement.** Firebase App Check is not enforced on the Cloud
Functions: the desktop application on Linux and Windows has no App Check
provider, so enforcing it would lock those clients out. Abuse resistance of the
backend relies instead on authentication (including verified email for admin
claims), per-user and per-IP quotas on the public callables and on telemetry,
and the server-side plan quotas of the AI proxy (daily turns, monthly tokens,
tier by capability). A script holding a valid account can therefore still call
the proxy, within those quotas.

**`enforceServerPrompt` is off by default.** While it is off, the AI proxy
accepts a client-supplied system prompt from clients older than 1.2.0. It will
be switched on (`config/aiPrompts`) once those clients are gone; from then on
the server uses only its own prompts.

**API keys embedded in the clients.** The keys shipped in the applications are
Firebase web keys, restricted on the GCP side to the Firebase APIs (verified
2026-11-02). HTTP referrer restrictions are not applied because the desktop
application sends no referrer.

## Privileged node shell

The node shell (Pro plan) is a root shell on the host of a node: Krufter creates
a **privileged debug pod with `hostPID`, `hostIPC`, `hostNetwork` and the host
namespaces entered through `nsenter`**. It is meant for cluster administrators
and is hardened as follows:

* **Consent first.** Nothing is created before you accept a dialog that names
  the node, says that a privileged pod with the host filesystem mounted will be
  created, shows the namespace used and lists the RBAC you need.
* **Pinned image.** The debug image is `alpine:3.22` pinned by digest
  (`alpine:3.22@sha256:...`, the multi-arch index), so the registry cannot swap
  what runs as root on your node. The digest is a single constant, refreshed on
  purpose. When the registry cannot be reached, only an official image already
  cached on the node (Docker Hub official repositories) is accepted, and the
  exact pinned digest is preferred when the node has it.
* **Dedicated namespace.** The pod lives in `krufter-debug`, created on demand
  with the labels `app.kubernetes.io/managed-by=krufter` and
  `pod-security.kubernetes.io/enforce=privileged`. If you are not allowed to
  create namespaces, Krufter warns you and falls back to your current
  namespace, where Pod Security Admission may refuse the pod (the error says
  so and what to do).
* **Bounded and cleaned up.** The pod is labelled, expires by itself after
  8 hours (`activeDeadlineSeconds`) and is deleted when the session ends. If the
  application was killed mid-session, the first shell panel opened for a context
  deletes the Krufter debug pods of `krufter-debug` older than 8 hours (errors
  are logged, never blocking). You can also remove them by hand:
  `kubectl -n krufter-debug delete pod -l app.kubernetes.io/managed-by=krufter`.
* **RBAC it needs.** `create`, `get` and `delete` on `pods`, `create` on
  `pods/attach` in that namespace, `get` on `nodes` (cached-image shortcut) and,
  optionally, `create` on `namespaces`. Anyone holding these rights can already
  get a root shell on the node by hand: Krufter does not add a privilege, it
  makes the use explicit and traceable.

## Safe harbour

If you act in good faith and follow this policy, we will consider your research
authorised: we will not take legal action against you and we will work with you
to understand and fix the issue. Good faith means:

* use your own accounts and your own clusters; do not access, modify or keep
  other people's data, and stop and tell us if you come across it;
* do not degrade the service for others (no load testing, no destructive
  actions, no spam);
* give us a reasonable time to fix the issue before any disclosure.

## No bug bounty, no certification

There is currently no paid bounty. Krufter has not had a third-party penetration
test and holds no SOC 2 or ISO 27001 certification; the page above says so
plainly and lists what we did instead.
