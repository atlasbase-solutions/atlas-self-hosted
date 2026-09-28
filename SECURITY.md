# Security policy

## Reporting a vulnerability

Do not report a suspected Atlas vulnerability in a public GitHub issue, pull request or discussion. Contact Atlas privately through [getatlasbase.com](https://getatlasbase.com/) and include:

- the distribution version (`release.json`, or `GET /version` of the affected service);
- the affected component (Portal, Tracking Gateway, edge, installer, operator tool) and endpoint;
- the conditions under which the issue reproduces, and its impact as you understand it.

Do not include customer data, production secrets, license strings, API keys, access tokens or live exploit traffic in the first message. Atlas will agree on a secure channel for anything sensitive.

## Supported versions

Security fixes are released as new patch versions of the current release line and published in this repository. Only the latest release receives fixes; `UPGRADE.md` describes the in-place upgrade from earlier 1.0.x releases.

New releases are delivered only to installations with a valid license: an installation whose license has expired or been revoked keeps running under the rules in `README.md`, and stops receiving new releases, including security fixes.

## Verifying what you run

Every release is signed offline with the Atlas release key. Before installing or upgrading, run `make verify-release` (or `./artifacts/linux-amd64/atlas-update-check -verify .`) and compare the printed key fingerprint with the one in `README.md` and in the Atlas documentation. Do not install a distribution whose signature does not verify.

## Operator responsibilities

The customer controls and is responsible for the self-hosted environment, including:

- host and Kubernetes security and patching;
- DNS, TLS outside the edge's `direct` mode, WAF, firewall and network policy;
- secrets management and rotation;
- image mirroring, scanning, signing and admission policy;
- data encryption and backup storage;
- monitoring, alerting, incident response and audit retention;
- access to Docker, Kubernetes, databases and persistent volumes;
- timely application of Atlas and third-party updates.

## Information for a support case

Include the output of `GET /version` from the portal and tracking hosts, and the result of `make verify-release`, in a private support case. Never publish env files, Kubernetes Secrets or license strings.
