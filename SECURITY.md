# Security policy

AndroBridge runs `adb` commands against your phone and moves files on your Mac, so command-injection or data-loss bugs matter.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. You'll get a reply within a week.

Useful details: the AndroBridge version, steps to reproduce, and what an attacker could achieve (for example a crafted file name that runs a command on the phone, or a transfer that deletes the source without a verified copy).

## Scope

In scope: command injection through file or folder names, paths escaping shared storage, transfers that overwrite or delete data without confirmation, verification bypasses.

Out of scope: issues in `adb` itself (report those to Google), and the general fact that USB debugging gives a trusted computer broad access to the phone.
