# Security policy

This repository contains only an allowlisted, sanitized subset of a workstation configuration.

## Publication controls

- Credentials, key material, browser profiles, histories, host identifiers, private media and application state are excluded.
- Deployment never deletes an existing file. Conflicts are moved to a timestamped backup under the user's state directory.
- `scripts/check.sh` runs filename, content, identity-path and private-network checks.
- Gitleaks scans both the working tree and Git history when installed.

## Reporting

If you find sensitive information, do not open a public issue containing it. Use GitHub's private vulnerability reporting for this repository.
