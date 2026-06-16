# ReaPack Packaging Notes

Verified against the current `reapack-index` packaging documentation.

## What Matters For This Project

- ReaPack package files must be in at least one subdirectory. Files at the repository root are not indexed.
- `.lua`, `.eel`, and `.py` package files are treated as ReaScripts.
- The only mandatory metadata tag is `@version`.
- `@description`, `@about`, `@link`, `@author`, and `@changelog` are supported and useful for a polished package.
- `@provides` can include multiple files in one package.
- For scripts, the package file itself defaults to `main`, meaning it is added to the REAPER Action List.
- Additional script files included through `@provides` default to `nomain`, meaning they are installed but not added to the Action List unless marked otherwise.
- `@noindex` is used for Lua files that should not be distributed as standalone packages.

## Recommendation

For the first public release, keep `ReaDLP.lua` as a single main file.

Reasons:

- It is the least fragile ReaPack path.
- Users get exactly one Action List entry.
- There are no `dofile`/module path issues.
- The current script is already working and self-contained.

After the package is stable, split-source development can be added internally:

```text
src/
  readlp_settings.lua
  readlp_paths.lua
  readlp_ytdlp.lua
  readlp_reaper.lua
  readlp_ui.lua
```

Then generate the public single-file script during release. That gives maintainability without increasing install risk.

## Multi-File Alternative

If helper files are eventually shipped directly through ReaPack, use `@provides` from the main script and mark helper Lua files with `@noindex` if they live where the indexer would otherwise treat them as packages.

Example shape:

```lua
-- @provides
--   [main] .
--   [nomain] ../lib/readlp_settings.lua > ReaDLP/readlp_settings.lua
```

This should be tested with `reapack-index --check` before publishing.

## Sources

- ReaPack package editor: https://reapack.com/upload/reascript
- ReaPack repository template: https://github.com/cfillion/reapack-repository-template
- `reapack-index` packaging documentation: https://github.com/cfillion/reapack-index/wiki/Packaging-Documentation
