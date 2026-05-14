# Supply Chain Security

Package installs are intentionally conservative.

## Release Age

Use a minimum package release age of at least seven days for npm, pnpm, bun, and uv when the package manager supports it.

Recommended settings:
- npm: `min-release-age=7`
- pnpm: `minimum-release-age=10080`
- bun: `minimumReleaseAge = 604800`
- uv: `exclude-newer = "7 days"`

## Install Failures

If dependency resolution fails because a package is too new:

1. Do not retry the same version repeatedly.
2. Check whether an older acceptable version satisfies the requirement.
3. Pin that older version explicitly.
4. If no viable older version exists, stop and ask the user for guidance.

## Install Scripts

Prefer disabled install scripts by default. If a package requires a post-install script, inspect the script first and run the minimum needed command intentionally.
