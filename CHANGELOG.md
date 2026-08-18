# Changelog

All notable changes to this action are recorded here. Versions follow semantic
versioning; callers should normally use the maintained `v1` major tag.

## v1.0.2 - 2026-08-18

- Made lifecycle resolution and Rabbit configuration merging self-contained.
- Added caller-selectable lifecycle policy and configuration-root inputs.
- Kept cloud identity in the caller workflow; the action consumes prepared
  runtime credentials only.

## v1.0.1 - 2026-04-30

- Initial GitHub Marketplace release.
