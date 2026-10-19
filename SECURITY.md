# Security Policy

This repository contains installer scripts intended to run on OpenWrt routers.

## Supported use

The default branch contains the current supported installer. When sharing install commands with other people, prefer a tagged release or a pinned commit URL instead of a moving `main` URL.

The bootstrap requires an explicit upstream release version and verifies the exact asset URL and SHA-256 digest from GitHub Release metadata. It refuses to upgrade an existing installation. Use RouterDesk for transactional updates and rollback; the bootstrap does not provide package rollback after a partial failure.

## Secrets and private data

Do not commit router passwords, SSH private keys, API tokens, `.env` files, router backups, customer-specific settings, or private support notes.

## Reporting a security issue

Do not disclose exploitable issues publicly before they are fixed. Report them through the existing private support channel for this project or contact the repository owner directly.

Useful report details:

- affected script;
- OpenWrt version and package manager (`apk` or `opkg`);
- exact command used, with secrets removed;
- expected behavior and actual behavior.
