# Palace Build Optimization Guide

## Quick Wins for Faster Builds

### 1. **Use Optimized Scripts** 
Replace aggressive cleaning with smart caching:

```bash
# Instead of: ./scripts/build-carthage.sh
./scripts/build-carthage-optimized.sh

# Instead of: source scripts/xcode-settings.sh  
source scripts/xcode-settings-optimized.sh
```

### 2. **Local Development Mode**
Set environment variable for faster local builds:
```bash
export BUILD_CONTEXT=dev
export CONFIGURATION=Debug
```

### 3. **Fastlane Development Lane**
Use the optimized development lane:
```bash
fastlane ios dev
```

## Build Time Breakdown & Optimizations

| Stage | Typical Time | Optimized Time | Optimization |
|-------|-------------|----------------|--------------|
| Carthage Clean + Build | 15-30 min | 2-5 min | Smart caching |
| Xcode Archive | 8-15 min | 6-10 min | Incremental builds |
| Export IPA | 2-5 min | 1-3 min | Skip unnecessary steps |
| **Total** | **25-50 min** | **9-18 min** | **~60% reduction** |

## Environment Variables for Performance

### Development Builds
```bash
export BUILD_CONTEXT=dev
export ONLY_ACTIVE_ARCH=YES
export DEBUG_INFORMATION_FORMAT=dwarf
export COMPILER_INDEX_STORE_ENABLE=NO
export SWIFT_INDEX_STORE_ENABLE=NO
```

### CI Builds
```bash
export BUILD_CONTEXT=ci
export FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT=600
export FASTLANE_XCODEBUILD_SETTINGS_RETRIES=2
```

## Caching Strategy

### Local Development
- **Carthage**: Uses `.carthage-cache/cartfile.hash` to detect changes
- **Build Settings**: Cached in `.build-cache/build-settings.cache`
- **DerivedData**: Preserved unless project changes significantly

### CI/GitHub Actions
- **Multi-level caching**: Dependencies, DerivedData, Build Settings
- **LFS caching**: For large binary dependencies (Adobe SDK)
- **Composite cache keys**: Based on Cartfile + Project + Xcode version

## Parallel Execution Opportunities

### Local Scripts
```bash
# Parallel repo setup
git clone repo1 & git clone repo2 & wait

# Parallel builds (where dependencies allow)
build_step_1 & build_step_2 & wait
```

### CI Workflows
- Repository checkouts in parallel
- Independent build steps (adhoc + appstore exports)
- Release notes generation during builds

## Clean Build When Needed

Only perform full clean builds when:
- Dependencies change (detected automatically)
- Switching between Debug/Release configurations
- Build errors suggest stale artifacts
- Weekly "hygiene" builds

Use `--force-clean` flag sparingly:
```bash
./scripts/build-carthage-optimized.sh --force-clean
```

## Monitoring Build Performance

### Local Timing
```bash
time ./scripts/your-build-script.sh
```

### CI Analytics
- GitHub Actions provides timing for each step
- Fastlane generates `fastlane/report.xml` with detailed metrics
- Custom timing logs in `.build-cache/timing.log`

## Xcode Project Optimizations

### Build Settings to Review
1. **Compilation Mode**: Ensure "Whole Module" for Release
2. **Debug Information**: Use `dwarf` for development, `dwarf-with-dsym` for distribution
3. **Architecture**: Use `ONLY_ACTIVE_ARCH=YES` for development
4. **Indexing**: Disable during CI builds

### Scheme Optimizations
1. Disable "Parallelize Build" only if it causes issues
2. Use "Build for Testing" + "Test without Building" for test runs
3. Consider separating build schemes for different purposes

## Common Anti-Patterns to Avoid

❌ **Don't do this:**
- `rm -rf ~/Library/Developer/Xcode/DerivedData/*` on every build
- `rm -rf ~/Library/Caches/org.carthage.CarthageKit` without reason
- Building all architectures during development
- Waiting for TestFlight processing in CI

✅ **Do this instead:**
- Use smart caching with change detection
- Preserve system caches when possible  
- Build only active architecture for development
- Skip waiting for build processing when possible

## Migration Guide

### Step 1: Backup Current Setup
```bash
cp scripts/build-carthage.sh scripts/build-carthage.sh.backup
cp fastlane/Fastfile fastlane/Fastfile.backup
```

### Step 2: Implement Optimized Scripts
- Replace `build-carthage.sh` with optimized version
- Update Fastfile with performance improvements
- Add caching directories to `.gitignore`

### Step 3: Test Locally
```bash
# Test optimized build
./scripts/build-carthage-optimized.sh

# Test development mode
BUILD_CONTEXT=dev fastlane ios dev
```

### Step 4: Update CI
- Implement caching in GitHub Actions
- Use parallel execution where possible
- Monitor build times and adjust

## Troubleshooting

### Build Fails After Optimization
1. Try with `--force-clean` flag
2. Check if cache directories are corrupted
3. Verify environment variables are set correctly

### Slower Than Expected
1. Check if caches are being invalidated unnecessarily
2. Verify parallel execution isn't causing conflicts
3. Monitor system resources during build

### Cache Issues
```bash
# Clear all optimization caches
rm -rf .carthage-cache .build-cache

# Clear system caches (last resort)
rm -rf ~/Library/Caches/org.carthage.CarthageKit
rm -rf ~/Library/Developer/Xcode/DerivedData
``` 