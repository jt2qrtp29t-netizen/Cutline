# Security Policy

## Supported versions

Only the latest release of Cutline gets security fixes. Cutline updates itself
(Cutline → Check for Updates…), so staying current is one click.

| Version | Supported |
| ------- | --------- |
| Latest release | ✅ |
| Anything older | ❌ |

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Go to the [Security tab](https://github.com/jt2qrtp29t-netizen/Cutline/security) of this repository.
2. Click **Report a vulnerability** and describe the problem, the Cutline version, and how to reproduce it.

Only the maintainer can see the report. Cutline is maintained by one person in their spare time, so replies
are best effort, but every report is read. Once a fix is released, the report can be published with credit
to you, if you'd like.

## What's in scope

Things that matter most:

- **Updates.** Cutline downloads new versions from this repository's GitHub Releases. Each download is checked
  against GitHub's SHA-256 digest and size, and must be Cutline at the promised version with an intact code
  signature before it's installed. A way around any of these checks is a serious issue.
- **Project files.** Opening a `.cutline` project, or media inside one, should never run code or touch files
  outside what the project uses.
- **Animate scripts.** Manim scripts are Python and run on your Mac. A script that comes from a project file
  rather than being typed by you must be approved before it runs. A way to make one run without that
  approval is in scope.

Out of scope: problems in Manim, Ollama or macOS themselves (please report those to their projects), and the
expected macOS warning on first launch, which appears because Cutline is ad-hoc signed rather than notarized.
