# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-03

### Added
- Initial stable release of `unbound-pkg`.
- `build.sh` script to download, compile, test, install, and rollback Unbound Debian packages.
- Local pre-installation snapshots with `apt-get download` for offline rollback capability.
- Automatic service restart gating using `policy-rc.d`.
- GPG signature checks for source package verification.
- `builder.conf` file for system variables and environment customizations.
- Comprehensive documentation in `README.md`.
- `AUTHOR.md` and `LICENSE` files (GPL v3).
- `PROJECT_STATE.md`, `DECISIONS.md`, and `CONTINUATION_PROMPT.md` for context handover.
