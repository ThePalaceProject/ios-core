# Releasing

Palace release process is automated and relies on Github workflow scripts. Workflow scripts create a new build every time a pull request is merged to the `develop` branch, make a new release on Github, and upload a new binary to Test Flight.

## Development Process

`develop` is the main development branch. 

Every new feature, bug fix or other task are developed on branches named following this naming convention:

- `feature/name` for new features;
- `fix/name` for bug fixes;
- `task/name` for miscellaneous tasks.

## Github Actions and the Release Process

### Palace Build

Location:  [.github/workflows/upload-on-merge.yml](https://github.com/ThePalaceProject/ios-core/blob/main/.github/workflows/upload-on-merge.yml)

Starts on merge to `develop` branch.

The script performs several steps:

- checks the project build version - if the version remains the same, the action stops; it helps to avoid unnecessary builds when updates are not related to the project itself, for example, changes in a CI script should not result in a new binary on Test Flight;
- generates release notes for Test Flight "What to Test" description;
- uploads a new build to Test Flight.

### Palace Manual Build

Location: [.github/workflows/upload.yml](https://github.com/ThePalaceProject/ios-core/blob/main/.github/workflows/upload.yml)

This script is similar to "Palace Build", but can be started manually. Performs the same set of steps.

### Palace Release

Location:  [.github/workflows/upload-on-merge.yml](https://github.com/ThePalaceProject/ios-core/blob/main/.github/workflows/release-on-merge.yml)

Starts on merge to `main` branch.

The script performs several steps:

- generates release notes for a new release on Github;
- creates a new release on Github.

### Palace Manual Release

Location:  [.github/workflows/upload-on-merge.yml](https://github.com/ThePalaceProject/ios-core/blob/main/.github/workflows/release.yml)

This script is similar to "Palace Release", but can be started manually. Performs the same set of steps.

### Unit Tests

Location: [.github/workflows/unit-testing.yml](https://github.com/ThePalaceProject/ios-core/blob/main/.github/workflows/unit-testing.yml)

Starts on pull request, can be started manually.

The script builds the project and runs unit tests.

## Release notes

We use a custom script to generate release notes. The script can be found in the `mobile-certificates` repository, [Certificates/Palace/iOS/ReleaseNotes.py](https://github.com/ThePalaceProject/mobile-certificates/blob/master/Certificates/Palace/iOS/ReleaseNotes.py).

The script collects titles of pull requests that were merged between releases, links to pull requests and links to Notion tickets, mentioned in the pulls.

Usage:

```python
python3 ReleaseNotes.py [-t TAG] [-v VERBOSITY]
```

where:

- -t TAG, --tag TAG: tag to start collecting release notes from. If omitted, collects from the latest tag available.
-  -v VERBOSITY, --verbosity VERBOSITY: how much information to show: 
    - 1 (default) - pull title only; 
    - 2 - title and links to PR and Notion ticket, markdown
                        format; 
    - 3 - title and Notion ticket link, when available

The `ios-core` repository contains [scripts/release-notes.sh](https://github.com/ThePalaceProject/ios-core/blob/develop/scripts/release-notes.sh) file that installs `request` module first (by default, not available on Github CI images).