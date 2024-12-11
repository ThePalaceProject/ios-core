![Palace Build](https://github.com/ThePalaceProject/ios-core/actions/workflows/upload-on-merge.yml/badge.svg) [![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# The Palace Project

This repository contains the client-side code for The Palace Project [Palace](https://thepalaceproject.org) application.

# System Requirements

- Install Xcode 16.1 in `/Applications`, open it and make sure to install additional components if it asks you.
- Install [Carthage](https://github.com/Carthage/Carthage) if you haven't already. Using `brew` is recommended.

If you run this project **with DRM support** on a Mac computer with Apple Silicon, make sure to check **[x]&nbsp;Open&nbsp;using&nbsp;Rosetta** in Xcode.app application info. This is required to build with Adobe DRM support. 

# Building without Adobe DRM nor Private Repos

```bash
git clone git@github.com:ThePalaceProject/ios-core.git
cd ios-core

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

Continuous integration is enabled on merge events on `develop` branch. Palace device builds are uploaded to [ios-binaries](https://github.com/ThePalaceProject/ios-binaries).

# Palace License

Copyright © 2021 LYRASIS

Licensed under the Apache License, Version 2.0 (the “License”); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an “AS IS” BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
