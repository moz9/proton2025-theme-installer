# Security Policy

This repository contains installer scripts intended to run on OpenWrt routers.

## Supported use

The default branch contains the current supported installer. When sharing install commands with other people, prefer a tagged release or a pinned commit URL instead of a moving `main` URL.

The installer requires an explicit upstream release version and verifies the exact asset URL and SHA-256 digest from GitHub Release metadata. Existing installations use the shared two-phase transaction in `lib/`, with a private local backup and independent confirmation deadline. RouterDesk also stores a verified encrypted copy on the PC. First-install bootstrap still does not provide full package rollback after partial failure.

Only the absent `uhttpd-mod-ubus` dependency may be added automatically, with exact uhttpd version compatibility and no collateral system upgrades. IPK feed signatures and hashes or native APK trust/solver checks are mandatory. Maintainer scripts are suppressed during transactional upgrades. The original web-server configuration and newly added module participate in rollback. Never weaken these checks to bypass a missing package.

Power failure/reboot recovery is not automatic. Do not delete the reported transaction directory until recovery is no longer needed. Built-in upstream LuCI updates are not patched into this transactional flow. Helper script hashes are pinned in the installer; update both copies and pins together and run the parity test before publication.

## Secrets and private data

Do not commit router passwords, SSH private keys, API tokens, `.env` files, router backups, customer-specific settings, or private support notes.

## Reporting a security issue

Do not disclose exploitable issues publicly before they are fixed. Report them through the existing private support channel for this project or contact the repository owner directly.

Useful report details:

- affected script;
- OpenWrt version and package manager (`apk` or `opkg`);
- exact command used, with secrets removed;
- expected behavior and actual behavior.
