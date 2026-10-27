# Security

Report security problems privately through GitHub's
[private vulnerability reporting](../../security/advisories/new), not in a public issue or discussion.
Please include the version, what you found and how to reproduce it.

Drifted is maintained in spare time and comes with no warranty or guaranteed response time (see
[LEGAL.md](LEGAL.md)). Reports are still read and taken seriously.

Things to know:

- The local API (port 8765) requires the token in `~/Library/Application Support/Drifted/token`. Anyone with
  the token can control the table. Treat it like a password.
- The API is meant for your computer and your local network. Don't forward it to the internet.
