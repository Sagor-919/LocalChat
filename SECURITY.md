# Security Policy

## Supported Versions

LocalChat is currently in alpha. Security fixes target the latest `main` branch and the most recent tagged release.

## Reporting a Vulnerability

Please do not report security issues in public GitHub issues.

Email: sagor@recklessgalaxy.com

Include:

- A short description of the issue
- Steps to reproduce or proof of concept
- Affected platform/version
- Potential impact
- Any suggested mitigation

We will acknowledge valid reports as soon as practical and coordinate a fix before public disclosure.

## Security Notes

LocalChat is designed for trusted local networks. It does not provide account identity, cloud relay, or internet-scale abuse protections. Message payloads are encrypted between peer IDs, but users should still treat unknown LAN peers with caution.
