# The Palace Project

This repository contains the client-side code for The Palace Project [Palace](https://thepalaceproject.org) application.

# System Requirements

- Install Xcode 12.4 in `/Applications`, open it and make sure to install additional components if it asks you.
- Install [Carthage](https://github.com/Carthage/Carthage) if you haven't already. Using `brew` is recommended.

# Building without Adobe DRM nor Private Repos

```bash
git clone git@github.com:ThePalaceProject/ios-core.git
cd ios-core
git checkout develop

# one-time set-up
./scripts/setup-repo-nodrm.sh

# idempotent script to rebuild all dependencies
./scripts/build-3rd-party-dependencies.sh --no-private
```
Open `Palace.xcodeproj` and build the `Palace-noDRM` target.

# Building With Adobe DRM

## Building the Application from Scratch

01. Contact project lead and ensure you have access to all the required private repos.
02. Then run:
```bash
git clone git@github.com:ThePalaceProject/ios-core.git
cd ios-core
./scripts/bootstrap-drm.sh
```
03. Open Palace.xcodeproj and build the `Palace` target.

## Building Dependencies Individually

Unless the DRM dependencies change (which is very seldom) you shouldn't need to run the `bootstrap-drm.sh` script more than once.

Other 3rd party dependencies are managed via Carthage and a few git submodules. To rebuild them you can use the following idempotent script:
```bash
cd ios-core
./scripts/build-3rd-party-dependencies.sh
```
The `scripts` directory contains a number of other scripts to build dependencies more granularly and also to build/archive/test the app from the command line. These scripts are the same used by our CI system. All these scripts must be run from the root of Palace `ios-core` repository, not from the `scripts` directory.

## Branching and CI

`develop` is the main development branch.

Release branch names follow the convention: `release/palace/<version>`. For example, `release/palace/1.0.0`.

Feature branch names (for features whose development is a month or more): `feature/<feature-name>`, e.g. `feature/my-new-screen`.

Continuous integration is enabled on push events on `develop`, release and feature branches. Palace device builds are uploaded to [ios-binaries](https://github.com/ThePalaceProject/ios-binaries). Commits on release branches also send the same build to TestFlight.
