# Contributing to Shot

Thanks for taking the time to contribute! Shot is a small, focused app, and contributions of every size are welcome,
from typo fixes to new features.

## Before you start

- **Bugs:** search [existing issues](https://github.com/eiskrenkov/shot/issues) first. If nothing matches,
  [open a bug report](https://github.com/eiskrenkov/shot/issues/new?template=bug_report.yml) with steps to reproduce,
  your macOS version and the Shot version (**Shot ▸ About Shot**).
- **Features:** please [open a feature request](https://github.com/eiskrenkov/shot/issues/new?template=feature_request.yml)
  before you write a lot of code, so we can agree on the approach. Shot deliberately stays small, so not every good
  idea will fit.
- **Security issues:** please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Development setup

Requirements: macOS 14 or later and Xcode 26 or later.

```sh
git clone https://github.com/eiskrenkov/shot.git
cd shot
open Shot.xcodeproj
```

`Shot.xcodeproj` is generated from [`project.yml`](project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit `project.yml` rather than the project's build settings in Xcode, and regenerate the project after adding,
removing or renaming files:

```sh
brew install xcodegen
xcodegen generate
```

Commit both `project.yml` and the regenerated `Shot.xcodeproj`. CI checks that they are in sync.

### Trying changes safely

Shot works on real files: grouping moves screenshots into folders, and *Move to Trash* trashes them. While developing,
point Shot at a scratch folder with a few test images (**Shot ▸ Settings… ▸ Change…**) rather than your real
screenshots folder.

## Code style

- Match the surrounding code. Shot is plain AppKit with no third-party dependencies, and it should stay that way.
- Prefer small, well-named types and functions over comments. Where a comment is needed, explain *why*.
- Keep UI behaviour consistent with macOS conventions: standard shortcuts, menu validation, responder chain.
- No new warnings. Build with `xcodebuild -project Shot.xcodeproj -scheme Shot build` before you open a PR.

## Pull requests

1. Fork the repository and branch from `master`.
2. Keep each pull request to a single change. Smaller PRs are reviewed faster.
3. Describe what changed and why, and include before/after screenshots for UI changes. Use mock data, not your
   personal screenshots.
4. Make sure CI passes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) and that you will
follow the [Code of Conduct](CODE_OF_CONDUCT.md).
