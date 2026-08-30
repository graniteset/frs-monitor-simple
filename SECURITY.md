# Security policy

## Supported version

This project is currently experimental. Security fixes apply to the latest
revision on the default branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting feature rather than opening
a public issue for authentication bypasses, path traversal, arbitrary file
access, or other security-sensitive findings.

## Deployment warning

The dashboard uses a random bearer token but does not provide TLS, user
accounts, rate limiting, or Internet-facing hardening. Keep it on a trusted LAN
or behind a private VPN. Do not expose its port directly to the public Internet.
