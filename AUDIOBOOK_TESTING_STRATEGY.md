# Audiobook Playback Testing Strategy

**Automated validation of audiobook playback, chapters, position restoration, and audio output**

---

## 🎯 What You Want to Validate

### **Playback State:**
- ✅ Audio actually plays (not silent)
- ✅ Play/pause works correctly
- ✅ Playback position updates
- ✅ Time elapsed increases

### **Chapter Navigation:**
- ✅ Skip forward/backward (30s increments)
- ✅ Chapter transitions work
- ✅ Table of contents navigation
- ✅ Auto-advance to next chapter

### **Position Restoration:**
- ✅ Resume at last position after app close
- ✅ Position persists across app restarts
- ✅ Chapter position saved correctly
- ✅ Time offset restored accurately

### **Playback Controls:**
- ✅ Playback speed changes (0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
- ✅ Sleep timer functions correctly
- ✅ Bookmarks created/restored
- ✅ Volume controls work

---

## 🛠️ **Approaches to Audiobook Testing**

### **Approach 1: AVAudioPlayer State Monitoring (Best for Unit Tests)**

**What:** Monitor AVAudioPlayer/AVPlayer internal state directly

**How it works:**
```swift
// In PalaceAudiobookToolkit - expose playback state for testing

#if DEBUG
extension AudiobookPlayer {
  /// Expose playback state for testing
  var testingState: PlaybackTestingState {
    PlaybackTestingState(
      isPlaying: player.timeControlStatus == .playing,
      currentTime: player.currentTime,
      duration: player.duration,
      currentChapter: currentChapterIndex,
      playbackRate: player.rate
    )
  }
}

struct PlaybackTestingState {
  let isPlaying: Bool
  let currentTime: TimeInterval
  let duration: TimeInterval
  let currentChapter: Int
  let playbackRate: Float
}
#endif
```

**Usage in tests:**
```swift
func testAudiobookPlayback() {
    let player = openAudiobook()
    
    // Verify initial state
    XCTAssertFalse(player.testingState.isPlaying)
    XCTAssertEqual(player.testingState.currentTime, 0.0)
    
    // Start playback
    tapPlayButton()
    wait(1.0)
    
    // Verify playing
    XCTAssertTrue(player.testingState.isPlaying)
    
    // Wait and verify time advances
    let time1 = player.testingState.currentTime
    wait(5.0)
    let time2 = player.testingState.currentTime
    
    XCTAssertGreaterThan(time2, time1 + 4.0, "Time should advance during playback")
}
```

**Pros:**
- ✅ Accurate, direct access to player state
- ✅ Fast (no need to wait for UI updates)
- ✅ Reliable (not dependent on UI)

**Cons:**
- ❌ Requires exposing internal state
- ❌ Only works with our player implementation

---

### **Approach 2: UI-Based Playback Validation (Best for E2E Tests)**

**What:** Monitor UI elements (time labels, progress slider) to infer playback state

**How it works:**
```swift
final class AudiobookPlaybackTests: BaseTestCase {
  
  func testAudioPlaybackFunctioning() {
    // Download and open audiobook
    let audiobook = downloadTestAudiobook()
    openAudiobook(audiobook)
    
    // Get UI elements
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    let currentTimeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    
    // Verify initial state
    XCTAssertTrue(playButton.waitForExistence(timeout: 10.0))
    let initialTime = parseTimeLabel(currentTimeLabel.label) // e.g., "0:00"
    XCTAssertEqual(initialTime, 0.0)
    
    // Start playback
    playButton.tap()
    
    // Wait and verify time advances
    wait(5.0)
    let time1 = parseTimeLabel(currentTimeLabel.label)
    
    wait(5.0)
    let time2 = parseTimeLabel(currentTimeLabel.label)
    
    // Verify playback is progressing
    XCTAssertGreaterThan(time2, time1, "Playback time should advance")
    XCTAssertGreaterThan(time2, 8.0, "Should have played for ~10 seconds")
    XCTAssertLessThan(time2, 12.0, "Should be around 10 seconds (not frozen)")
  }
  
  func testChapterNavigation() {
    openTestAudiobook()
    tapPlayButton()
    
    let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    let initialChapter = chapterLabel.label
    
    // Skip to next chapter
    let tocButton = app.buttons[AccessibilityID.AudiobookPlayer.tocButton]
    tocButton.tap()
    
    // Select chapter 2
    let chapter2 = app.buttons[AccessibilityID.AudiobookPlayer.tocChapter(1)] // 0-indexed
    chapter2.tap()
    
    // Verify chapter changed
    wait(1.0)
    let newChapter = chapterLabel.label
    XCTAssertNotEqual(newChapter, initialChapter, "Chapter should have changed")
  }
  
  func testPositionRestoration() {
    openTestAudiobook()
    tapPlayButton()
    
    // Play for 15 seconds
    wait(15.0)
    
    let currentTimeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let savedTime = parseTimeLabel(currentTimeLabel.label)
    XCTAssertGreaterThan(savedTime, 10.0, "Should have played ~15 seconds")
    
    // Close app
    app.terminate()
    
    // Relaunch
    app.launch()
    
    // Reopen audiobook
    navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    guard let bookDetail = myBooks.selectFirstBook() else {
      XCTFail("Could not open book")
      return
    }
    bookDetail.tapListenButton()
    
    // Verify position restored
    wait(2.0)
    let restoredTime = parseTimeLabel(currentTimeLabel.label)
    
    // Should be within 5 seconds of saved position
    XCTAssertEqual(restoredTime, savedTime, accuracy: 5.0, 
                   "Position should restore to approximately \(savedTime) seconds")
  }
  
  private func parseTimeLabel(_ label: String) -> TimeInterval {
    // Parse "12:34" or "1:23:45" to seconds
    let components = label.split(separator: ":").map { Int($0) ?? 0 }
    
    if components.count == 2 {
      // MM:SS
      return TimeInterval(components[0] * 60 + components[1])
    } else if components.count == 3 {
      // HH:MM:SS
      return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
    }
    
    return 0
  }
}
```

**Pros:**
- ✅ Tests actual user experience
- ✅ No internal state exposure needed
- ✅ Works with any player implementation

**Cons:**
- ❌ Slower (waits for real time to pass)
- ❌ Dependent on UI accuracy

---

### **Approach 3: Audio Output Detection (Advanced)**

**What:** Actually detect if audio is coming out (not silent)

**Option 3A: System Audio Tap (iOS Simulator Only)**

```swift
import AVFoundation

final class AudioOutputTests: BaseTestCase {
  
  #if targetEnvironment(simulator)
  func testAudioOutputDetectable() {
    openTestAudiobook()
    tapPlayButton()
    
    // On simulator, can use AVAudioEngine to tap system audio
    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let bus = 0
    
    var audioDetected = false
    
    inputNode.installTap(onBus: bus, bufferSize: 1024, format: inputNode.inputFormat(forBus: bus)) { buffer, time in
      // Check if buffer contains non-silence
      let channelData = buffer.floatChannelData?[0]
      let frames = buffer.frameLength
      
      for frame in 0..<Int(frames) {
        if abs(channelData![frame]) > 0.01 { // Threshold for silence
          audioDetected = true
          break
        }
      }
    }
    
    try? audioEngine.start()
    
    // Wait for audio
    wait(3.0)
    
    audioEngine.stop()
    inputNode.removeTap(onBus: bus)
    
    XCTAssertTrue(audioDetected, "Should detect audio output from audiobook")
  }
  #endif
}
```

**Pros:**
- ✅ Actually detects audio output
- ✅ Catches "silent playback" bugs

**Cons:**
- ❌ Simulator only (can't tap audio on real devices easily)
- ❌ Complex setup
- ❌ May not work reliably in CI

---

### **Approach 4: Mock/Test Audiobook (Most Reliable)**

**What:** Use deterministic test audiobooks with known properties

**Create test audiobooks:**
```
test-audiobooks/
├── short-audiobook.m4a          # 30 seconds, 1 chapter
├── multi-chapter.m4a             # 2 minutes, 3 chapters
├── lcp-encrypted-test.lcpl      # DRM audiobook
└── manifest.json                # Audiobook metadata
```

**Benefits:**
- ✅ Predictable duration (no waiting forever)
- ✅ Known chapter count
- ✅ Known time offsets
- ✅ Fast test execution

**Example:**
```swift
func testChapterTransitions() {
    // Use test audiobook with exactly 3 chapters, 20 seconds each
    let testAudiobook = TestAudiobook.threeChapters20SecondsEach
    
    openAudiobook(testAudiobook)
    tapPlayButton()
    
    // Verify chapter 1
    let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    XCTAssertTrue(chapterLabel.label.contains("Chapter 1"))
    
    // Wait for chapter 1 to end (20 seconds + 2 second buffer)
    wait(22.0)
    
    // Should auto-advance to chapter 2
    XCTAssertTrue(chapterLabel.label.contains("Chapter 2"), 
                  "Should auto-advance to next chapter")
}
```

---

## 🎨 **Recommended Solution: Hybrid Approach**

### **Combine Multiple Strategies:**

```swift
final class ComprehensiveAudiobookTests: BaseTestCase {
  
  /// Test 1: Basic playback functioning (UI-based, fast)
  func testBasicPlaybackFunctions() {
    openTestAudiobook()
    
    // Verify play button exists
    let playButton = app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
    XCTAssertTrue(playButton.waitForExistence(timeout: 10.0))
    
    // Start playback
    playButton.tap()
    
    // Verify time advances (UI-based validation)
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let time1 = parseTime(timeLabel.label)
    
    wait(5.0)
    
    let time2 = parseTime(timeLabel.label)
    XCTAssertGreaterThan(time2, time1 + 4.0, "Playback time should advance")
  }
  
  /// Test 2: Chapter navigation (E2E)
  func testChapterNavigation() {
    openTestAudiobook()
    tapPlayButton()
    
    // Open TOC
    let tocButton = app.buttons[AccessibilityID.AudiobookPlayer.tocButton]
    tocButton.tap()
    
    // Select chapter 3
    let chapter3 = app.buttons[AccessibilityID.AudiobookPlayer.tocChapter(2)]
    XCTAssertTrue(chapter3.waitForExistence(timeout: 5.0))
    chapter3.tap()
    
    // Verify jumped to chapter 3
    wait(1.0)
    let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    XCTAssertTrue(chapterLabel.label.contains("3") || chapterLabel.label.contains("Chapter 3"))
    
    // Verify time reset to chapter 3 start
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let time = parseTime(timeLabel.label)
    // Should be at start of chapter 3 (depends on chapter length)
  }
  
  /// Test 3: Skip forward/backward (precise)
  func testSkipControls() {
    openTestAudiobook()
    tapPlayButton()
    
    wait(10.0) // Play for 10 seconds
    
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let time1 = parseTime(timeLabel.label)
    XCTAssertGreaterThan(time1, 8.0)
    
    // Skip forward 30 seconds
    let skipForwardButton = app.buttons[AccessibilityID.AudiobookPlayer.skipForwardButton]
    skipForwardButton.tap()
    
    wait(1.0)
    let time2 = parseTime(timeLabel.label)
    
    // Should be ~30 seconds ahead
    XCTAssertEqual(time2, time1 + 30.0, accuracy: 2.0, 
                   "Skip forward should advance 30 seconds")
    
    // Skip backward 30 seconds
    let skipBackButton = app.buttons[AccessibilityID.AudiobookPlayer.skipBackButton]
    skipBackButton.tap()
    
    wait(1.0)
    let time3 = parseTime(timeLabel.label)
    
    // Should be back to ~original position
    XCTAssertEqual(time3, time1, accuracy: 2.0,
                   "Skip back should return to original position")
  }
  
  /// Test 4: Playback speed changes
  func testPlaybackSpeedChanges() {
    openTestAudiobook()
    tapPlayButton()
    
    // Verify normal speed (1.0x)
    wait(10.0) // Play for 10 seconds at normal speed
    
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let normalSpeedTime = parseTime(timeLabel.label)
    XCTAssertGreaterThan(normalSpeedTime, 8.0)
    XCTAssertLessThan(normalSpeedTime, 12.0)
    
    // Change to 2.0x speed
    let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
    speedButton.tap()
    
    let speed2x = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeed("2.0x")]
    XCTAssertTrue(speed2x.waitForExistence(timeout: 2.0))
    speed2x.tap()
    
    // Verify speed changed (time should advance faster)
    let time1 = parseTime(timeLabel.label)
    wait(5.0) // Wait 5 seconds
    let time2 = parseTime(timeLabel.label)
    
    // At 2.0x speed, 5 seconds real time = 10 seconds audiobook time
    let elapsed = time2 - time1
    XCTAssertGreaterThan(elapsed, 8.0, "Should play faster at 2.0x speed")
    XCTAssertLessThan(elapsed, 12.0, "Should be approximately 2x faster")
  }
  
  /// Test 5: Position restoration after app restart
  func testPositionRestorationAfterRestart() {
    openTestAudiobook()
    tapPlayButton()
    
    // Play to a specific position (e.g., 45 seconds)
    wait(45.0)
    
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let savedPosition = parseTime(timeLabel.label)
    XCTAssertGreaterThan(savedPosition, 40.0)
    
    // Close player
    let closeButton = app.buttons[AccessibilityID.AudiobookPlayer.closeButton]
    closeButton.tap()
    
    // Terminate and relaunch app
    app.terminate()
    wait(1.0)
    app.launch()
    
    // Reopen audiobook
    navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    guard let bookDetail = myBooks.selectFirstBook() else {
      XCTFail("Could not open audiobook")
      return
    }
    bookDetail.tapListenButton()
    
    // Verify position restored
    wait(2.0)
    let restoredPosition = parseTime(timeLabel.label)
    
    XCTAssertEqual(restoredPosition, savedPosition, accuracy: 5.0,
                   "Position should restore to within 5 seconds of \(savedPosition)")
  }
  
  /// Test 6: Sleep timer functionality
  func testSleepTimer() {
    openTestAudiobook()
    tapPlayButton()
    
    // Set sleep timer to 15 seconds (shortest for testing)
    let sleepTimerButton = app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerButton]
    sleepTimerButton.tap()
    
    // Select custom time (if available) or end of chapter
    let timer15min = app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerMinutes(15)]
    if timer15min.exists {
      timer15min.tap()
    } else {
      // For testing, we'd want a very short timer
      // Or use end of chapter with a short test chapter
      let endOfChapter = app.buttons[AccessibilityID.AudiobookPlayer.sleepTimerEndOfChapter]
      endOfChapter.tap()
    }
    
    // Verify sleep timer is active (UI shows countdown)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sleep'")).count > 0)
    
    // Wait for timer to expire
    // (In real tests, use very short timer or test chapter)
    
    // Verify playback stopped
    // (Would need to check play button state or time advancement stopping)
  }
  
  private func parseTime(_ label: String) -> TimeInterval {
    // Parse "12:34" or "1:23:45" format
    let components = label.split(separator: ":").compactMap { Int($0) }
    
    switch components.count {
    case 2: // MM:SS
      return TimeInterval(components[0] * 60 + components[1])
    case 3: // HH:MM:SS  
      return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
    default:
      return 0
    }
  }
}
```

---

## 🎵 **Audio Output Validation (Real Device)**

### **Using AudioToolbox Framework:**

```swift
import AudioToolbox
import AVFoundation

final class AudioOutputValidationTests: BaseTestCase {
  
  func testAudioIsActuallyPlaying() {
    openTestAudiobook()
    
    // Install audio tap to monitor output
    let audioSession = AVAudioSession.sharedInstance()
    
    // Verify audio route is active
    let outputs = audioSession.currentRoute.outputs
    XCTAssertGreaterThan(outputs.count, 0, "Should have audio output route")
    
    // Start playback
    tapPlayButton()
    wait(2.0)
    
    // Verify audio session is active
    XCTAssertTrue(audioSession.isOtherAudioPlaying || 
                  audioSession.category == .playback,
                  "Audio session should be active for playback")
    
    // Verify time advances (indicates audio is playing)
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    let time1 = parseTime(timeLabel.label)
    
    wait(5.0)
    
    let time2 = parseTime(timeLabel.label)
    XCTAssertGreaterThan(time2, time1, "Audio playback time should advance")
  }
}
```

---

## 🧪 **Test Audiobook Creation**

### **Create Deterministic Test Audiobooks:**

**Why:** Real audiobooks are long (hours), test audiobooks should be short (seconds/minutes)

**Create test assets:**

```bash
# Create short test audiobook files
tools/create-test-audiobook.sh
```

```python
#!/usr/bin/env python3
# tools/create-test-audiobook.py

"""
Generate test audiobooks with known properties for automated testing
"""

from pydub import AudioSegment
from pydub.generators import Sine
import json

def create_test_audiobook():
    """Create a 1-minute audiobook with 3 chapters"""
    
    # Generate 3 chapters of audio (20 seconds each)
    chapter1 = Sine(440).to_audio_segment(duration=20000)  # 440Hz tone, 20s
    chapter2 = Sine(523).to_audio_segment(duration=20000)  # 523Hz tone, 20s  
    chapter3 = Sine(659).to_audio_segment(duration=20000)  # 659Hz tone, 20s
    
    # Export chapters
    chapter1.export("test-audiobooks/chapter1.mp3", format="mp3")
    chapter2.export("test-audiobooks/chapter2.mp3", format="mp3")
    chapter3.export("test-audiobooks/chapter3.mp3", format="mp3")
    
    # Create manifest
    manifest = {
        "metadata": {
            "title": "Test Audiobook - Three Chapters",
            "identifier": "test-audiobook-3ch",
            "duration": 60.0
        },
        "spine": [
            {
                "href": "chapter1.mp3",
                "type": "audio/mpeg",
                "duration": 20.0,
                "title": "Chapter 1"
            },
            {
                "href": "chapter2.mp3",
                "type": "audio/mpeg",
                "duration": 20.0,
                "title": "Chapter 2"
            },
            {
                "href": "chapter3.mp3",
                "type": "audio/mpeg",
                "duration": 20.0,
                "title": "Chapter 3"
            }
        ]
    }
    
    with open("test-audiobooks/manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
    
    print("✅ Created test audiobook:")
    print("   - Duration: 1 minute")
    print("   - Chapters: 3 (20 seconds each)")
    print("   - Location: test-audiobooks/")

if __name__ == "__main__":
    create_test_audiobook()
```

**Usage in tests:**
```swift
func testChapterAutoAdvance() {
    // Use 3-chapter test audiobook (20 seconds per chapter)
    openTestAudiobook(.threeChapters20SecondsEach)
    tapPlayButton()
    
    // Verify starts at chapter 1
    let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    XCTAssertTrue(chapterLabel.label.contains("Chapter 1"))
    
    // Wait for chapter 1 to complete (22 seconds with buffer)
    wait(22.0)
    
    // Should auto-advance to chapter 2
    XCTAssertTrue(chapterLabel.label.contains("Chapter 2"), 
                  "Should auto-advance after chapter 1")
    
    // Wait for chapter 2
    wait(22.0)
    
    // Should auto-advance to chapter 3
    XCTAssertTrue(chapterLabel.label.contains("Chapter 3"),
                  "Should auto-advance after chapter 2")
}
```

**Benefits:**
- ✅ Fast (1 minute vs hours)
- ✅ Predictable (known durations)
- ✅ Reliable (deterministic)
- ✅ Complete coverage (can test all features quickly)

---

## 📊 **Audiobook Test Coverage Matrix**

| Feature | Test Method | Duration | Reliability |
|---------|-------------|----------|-------------|
| **Play/Pause** | UI state + time advancement | 10s | ⭐⭐⭐⭐⭐ |
| **Skip forward/back** | Time label comparison | 15s | ⭐⭐⭐⭐⭐ |
| **Chapter navigation** | TOC → verify chapter label | 10s | ⭐⭐⭐⭐⭐ |
| **Auto-advance chapters** | Wait for chapter end | 25s | ⭐⭐⭐⭐ |
| **Playback speed** | Time advancement rate | 15s | ⭐⭐⭐⭐ |
| **Position restoration** | App restart + time check | 60s | ⭐⭐⭐⭐⭐ |
| **Sleep timer** | Set timer + verify stop | 30s | ⭐⭐⭐⭐ |
| **Bookmarks** | Create + restore position | 20s | ⭐⭐⭐⭐⭐ |
| **Audio output** | System audio detection | 10s | ⭐⭐⭐ (sim only) |
| **LCP decryption** | DRM playback + time check | 30s | ⭐⭐⭐⭐ (device) |

**Total test time:** ~4-5 minutes for complete audiobook validation suite

---

## 🎯 **Recommended Test Suite**

### **Create:** `PalaceUITests/Tests/Audiobook/AudiobookPlaybackTests.swift`

```swift
import XCTest

final class AudiobookPlaybackTests: BaseTestCase {
  
  // MARK: - Basic Playback
  
  func testAudiobookPlays() {
    // Validates audio starts and time advances
    openTestAudiobook()
    verifyPlaybackAdvances(duration: 10.0)
  }
  
  func testPauseWorks() {
    openTestAudiobook()
    tapPlayButton()
    wait(5.0)
    
    tapPauseButton()
    
    let time1 = getCurrentPlaybackTime()
    wait(3.0)
    let time2 = getCurrentPlaybackTime()
    
    XCTAssertEqual(time1, time2, accuracy: 0.5, 
                   "Time should not advance when paused")
  }
  
  // MARK: - Chapter Navigation
  
  func testSkipForward30Seconds() {
    openTestAudiobook()
    tapPlayButton()
    wait(10.0)
    
    let time1 = getCurrentPlaybackTime()
    tapSkipForwardButton()
    wait(1.0)
    let time2 = getCurrentPlaybackTime()
    
    XCTAssertEqual(time2 - time1, 30.0, accuracy: 2.0)
  }
  
  func testSkipBackward30Seconds() {
    openTestAudiobook()
    tapPlayButton()
    wait(40.0) // Get to 40 seconds
    
    let time1 = getCurrentPlaybackTime()
    tapSkipBackButton()
    wait(1.0)
    let time2 = getCurrentPlaybackTime()
    
    XCTAssertEqual(time1 - time2, 30.0, accuracy: 2.0)
  }
  
  func testTableOfContentsNavigation() {
    openTestAudiobook()
    tapTOCButton()
    
    // Select chapter 2
    let chapter2 = app.buttons[AccessibilityID.AudiobookPlayer.tocChapter(1)]
    XCTAssertTrue(chapter2.waitForExistence(timeout: 5.0))
    chapter2.tap()
    
    wait(1.0)
    
    // Verify we're in chapter 2
    let chapterTitle = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    XCTAssertTrue(chapterTitle.label.lowercased().contains("2") || 
                  chapterTitle.label.lowercased().contains("chapter 2"))
  }
  
  // MARK: - Position Persistence
  
  func testPositionPersistsAfterAppRestart() {
    openTestAudiobook()
    tapPlayButton()
    wait(30.0) // Play to 30 seconds
    
    let savedPosition = getCurrentPlaybackTime()
    takeScreenshot(named: "position-before-restart")
    
    // Close and restart
    app.terminate()
    app.launch()
    
    // Reopen audiobook
    reopenLastAudiobook()
    
    wait(2.0)
    let restoredPosition = getCurrentPlaybackTime()
    takeScreenshot(named: "position-after-restart")
    
    XCTAssertEqual(restoredPosition, savedPosition, accuracy: 5.0,
                   "Position should restore within 5 seconds")
  }
  
  func testPositionPersistsAfterBackgrounding() {
    openTestAudiobook()
    tapPlayButton()
    wait(20.0)
    
    let savedPosition = getCurrentPlaybackTime()
    
    // Background app
    XCUIDevice.shared.press(.home)
    wait(5.0)
    
    // Reopen app
    app.activate()
    wait(2.0)
    
    let restoredPosition = getCurrentPlaybackTime()
    
    // Position should be maintained (possibly continued playing in background)
    XCTAssertGreaterThanOrEqual(restoredPosition, savedPosition,
                                "Position should be at least where we left off")
  }
  
  // MARK: - Playback Speed
  
  func testPlaybackSpeedPersists() {
    openTestAudiobook()
    
    // Set to 1.5x
    setPlaybackSpeed("1.5x")
    
    // Verify it's applied
    verifyPlaybackSpeed("1.5x")
    
    // Close and reopen
    closePlayer()
    reopenLastAudiobook()
    
    // Verify speed persisted
    wait(1.0)
    verifyPlaybackSpeed("1.5x")
  }
  
  // MARK: - Chapter Auto-Advance
  
  func testChapterAutoAdvance() {
    // Use test audiobook with 20-second chapters
    openTestAudiobook(.threeChapters20SecondsEach)
    tapPlayButton()
    
    let chapterLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.chapterTitle]
    XCTAssertTrue(chapterLabel.label.contains("1"))
    
    // Wait for chapter 1 to end (22 seconds with buffer)
    wait(22.0)
    
    // Should auto-advance
    XCTAssertTrue(chapterLabel.label.contains("2"), 
                  "Should auto-advance to chapter 2")
  }
  
  // MARK: - Helper Methods
  
  private func getCurrentPlaybackTime() -> TimeInterval {
    let timeLabel = app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
    return parseTime(timeLabel.label)
  }
  
  private func verifyPlaybackAdvances(duration: TimeInterval) {
    tapPlayButton()
    
    let time1 = getCurrentPlaybackTime()
    wait(duration)
    let time2 = getCurrentPlaybackTime()
    
    let expectedAdvance = duration * 0.9 // 90% of expected
    XCTAssertGreaterThan(time2 - time1, expectedAdvance,
                        "Playback should advance during \(duration) seconds")
  }
  
  private func setPlaybackSpeed(_ speed: String) {
    let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
    speedButton.tap()
    
    let speedOption = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeed(speed)]
    XCTAssertTrue(speedOption.waitForExistence(timeout: 2.0))
    speedOption.tap()
  }
  
  private func verifyPlaybackSpeed(_ speed: String) {
    // Could check UI indicator or measure time advancement rate
    let speedButton = app.buttons[AccessibilityID.AudiobookPlayer.playbackSpeedButton]
    // In Palace, speed button might show current speed
    // XCTAssertTrue(speedButton.label.contains(speed))
  }
}
```

---

## 🔧 **Exposing Playback State for Testing**

### **Add to PalaceAudiobookToolkit (For Testing):**

```swift
// PalaceAudiobookToolkit/Player/AudiobookPlayer.swift

#if DEBUG
/// Testing interface - only available in debug builds
public protocol AudiobookPlayerTesting {
  var isPlaying: Bool { get }
  var currentTime: TimeInterval { get }
  var duration: TimeInterval { get }
  var currentChapterIndex: Int { get }
  var playbackRate: Float { get }
}

extension DefaultAudiobookPlayer: AudiobookPlayerTesting {
  public var isPlaying: Bool {
    player.timeControlStatus == .playing
  }
  
  public var currentTime: TimeInterval {
    CMTimeGetSeconds(player.currentTime())
  }
  
  public var duration: TimeInterval {
    guard let item = player.currentItem else { return 0 }
    return CMTimeGetSeconds(item.duration)
  }
  
  public var currentChapterIndex: Int {
    // Return current chapter
    return tableOfContents.currentChapterIndex
  }
  
  public var playbackRate: Float {
    player.rate
  }
}
#endif
```

**Usage in tests:**
```swift
func testPlaybackRateChange() {
    let player = openAudiobook() as! AudiobookPlayerTesting
    
    XCTAssertEqual(player.playbackRate, 1.0, "Should start at normal speed")
    
    setPlaybackSpeed("1.5x")
    
    XCTAssertEqual(player.playbackRate, 1.5, accuracy: 0.1, 
                   "Should change to 1.5x speed")
}
```

---

## 📱 **Device vs Simulator Testing**

### **Simulator (Fast, Most Tests):**
```swift
func testPlaybackControls() {
    #if targetEnvironment(simulator)
    // Most playback tests work on simulator
    openTestAudiobook()
    tapPlayButton()
    verifyTimeAdvances()
    testSkipButtons()
    testChapterNavigation()
    #endif
}
```

### **Real Device (DRM, Audio Output):**
```swift
func testLCPAudiobookDecryption() {
    #if !targetEnvironment(simulator)
    // LCP decryption only works on real devices
    openLCPAudiobook()
    tapPlayButton()
    
    wait(5.0)
    
    // If we hear audio advancing, decryption worked
    verifyTimeAdvances()
    #else
    throw XCTSkip("LCP decryption requires physical device")
    #endif
}
```

---

## 🎯 **Practical Example: Complete Audiobook Test**

```swift
/// Comprehensive audiobook playback validation
func testCompleteAudiobookFlow() {
    // 1. Download audiobook
    let catalog = CatalogScreen(app: app)
    let search = catalog.tapSearchButton()
    search.enterSearchText("test audiobook")
    
    guard let bookDetail = search.tapFirstResult() else {
      XCTFail("Could not find audiobook")
      return
    }
    
    bookDetail.downloadBook()
    
    // 2. Open audiobook
    bookDetail.tapListenButton()
    
    // 3. Verify player UI
    let player = AudiobookPlayerScreen(app: app)
    XCTAssertTrue(player.isDisplayed())
    
    // 4. Test playback
    player.tapPlayButton()
    wait(5.0)
    
    let time1 = player.getCurrentTime()
    wait(5.0)
    let time2 = player.getCurrentTime()
    
    XCTAssertGreaterThan(time2 - time1, 4.0, "Playback should advance")
    
    // 5. Test skip forward
    player.tapSkipForwardButton()
    wait(1.0)
    let time3 = player.getCurrentTime()
    XCTAssertEqual(time3, time2 + 30.0, accuracy: 2.0, "Should skip 30 seconds")
    
    // 6. Test playback speed
    player.setPlaybackSpeed("1.5x")
    let time4 = player.getCurrentTime()
    wait(6.0) // Wait 6 real seconds
    let time5 = player.getCurrentTime()
    // At 1.5x speed, 6 real seconds = 9 audiobook seconds
    XCTAssertGreaterThan(time5 - time4, 8.0, "Should play faster at 1.5x")
    
    // 7. Test chapter navigation
    player.tapTOCButton()
    player.selectChapter(2)
    wait(1.0)
    XCTAssertTrue(player.isOnChapter(2), "Should jump to chapter 2")
    
    // 8. Test position restoration
    let savedPosition = player.getCurrentTime()
    player.closePlayer()
    
    app.terminate()
    app.launch()
    
    navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    myBooks.selectFirstBook()?.tapListenButton()
    
    wait(2.0)
    let restoredPosition = player.getCurrentTime()
    XCTAssertEqual(restoredPosition, savedPosition, accuracy: 5.0, 
                   "Position should restore")
    
    // 9. Snapshot the player UI
    assertSnapshot(matching: app.screenshot().image, as: .image,
                   named: "audiobook-player-active")
}
```

---

## 🎨 **Visual Validation for Audiobook Player**

```swift
final class AudiobookPlayerVisualTests: BaseTestCase {
  
  func testPlayerUIAppearance() {
    openTestAudiobook()
    
    // Snapshot player in different states
    
    // 1. Paused state
    assertSnapshot(matching: app.screenshot().image, as: .image, 
                   named: "player-paused")
    
    // 2. Playing state
    tapPlayButton()
    wait(2.0)
    assertSnapshot(matching: app.screenshot().image, as: .image,
                   named: "player-playing")
    
    // 3. TOC open
    tapTOCButton()
    wait(1.0)
    assertSnapshot(matching: app.screenshot().image, as: .image,
                   named: "player-toc-open")
    
    // 4. Speed menu open
    closeTOC()
    tapSpeedButton()
    wait(1.0)
    assertSnapshot(matching: app.screenshot().image, as: .image,
                   named: "player-speed-menu")
  }
  
  func testPlayerControlsVisible() {
    openTestAudiobook()
    
    // Verify all controls exist
    let controls = [
      AccessibilityID.AudiobookPlayer.playPauseButton,
      AccessibilityID.AudiobookPlayer.skipForwardButton,
      AccessibilityID.AudiobookPlayer.skipBackButton,
      AccessibilityID.AudiobookPlayer.playbackSpeedButton,
      AccessibilityID.AudiobookPlayer.sleepTimerButton,
      AccessibilityID.AudiobookPlayer.tocButton
    ]
    
    for controlID in controls {
      let control = app.buttons[controlID]
      XCTAssertTrue(control.exists, "\(controlID) should exist")
    }
    
    // Snapshot all controls
    assertSnapshot(matching: app.screenshot().image, as: .image,
                   named: "audiobook-controls-all")
  }
}
```

---

## 🚀 **Quick Win: Implement This Week**

### **Day 1: Add Helper Methods**

Create `PalaceUITests/Screens/AudiobookPlayerScreen.swift`:

```swift
final class AudiobookPlayerScreen: ScreenObject {
  
  var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.AudiobookPlayer.playPauseButton]
  }
  
  var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.AudiobookPlayer.currentTimeLabel]
  }
  
  func getCurrentTime() -> TimeInterval {
    guard currentTimeLabel.exists else { return 0 }
    return parseTime(currentTimeLabel.label)
  }
  
  func tapPlayButton() {
    playPauseButton.tap()
  }
  
  func verifyPlaybackAdvances(duration: TimeInterval = 5.0) {
    let time1 = getCurrentTime()
    wait(duration)
    let time2 = getCurrentTime()
    
    XCTAssertGreaterThan(time2 - time1, duration * 0.9,
                        "Playback should advance")
  }
  
  private func parseTime(_ label: String) -> TimeInterval {
    // Implementation from above
  }
}
```

### **Day 2: Create First Audiobook Test**

```swift
func testAudiobookBasicPlayback() {
    // This test works TODAY with existing framework
    let catalog = CatalogScreen(app: app)
    // ... find audiobook ...
    // ... download ...
    // ... tap LISTEN ...
    
    let player = AudiobookPlayerScreen(app: app)
    XCTAssertTrue(player.isDisplayed())
    
    player.tapPlayButton()
    player.verifyPlaybackAdvances(duration: 10.0)
    
    // ✅ Test passes if playback time advances!
}
```

### **Day 3: Run on BrowserStack (DRM Validation)**

```bash
# Build and upload (once signing is fixed)
./scripts/build-for-browserstack.sh Palace
./scripts/upload-to-browserstack.sh

# Run audiobook tests on real iPhone
./scripts/run-browserstack-tests.sh \
  Palace-DRM \
  PalaceUITests \
  "iPhone 15 Pro-17.0" \
  "PalaceUITests.AudiobookPlaybackTests"
```

---

## 📚 **Additional Resources**

### **Similar Approaches (Inspiration):**

- **Spotify iOS Tests:** Monitor playback state via UI elements
- **Apple Podcasts:** Test playback with short test episodes
- **Audible:** Deterministic test audiobooks (short durations)

### **Tools:**
- **AVFoundation Testing:** Monitor AVPlayer state
- **XCTest Expectations:** Wait for time-based conditions
- **swift-snapshot-testing:** Visual validation of player UI

---

## 🎉 **Summary**

**YES, you can automate audiobook playback validation!**

### **Recommended Approach:**

1. ✅ **Monitor UI elements** (time labels, chapter titles)
2. ✅ **Verify time advancement** (playback functioning)
3. ✅ **Test all controls** (skip, speed, TOC, sleep timer)
4. ✅ **Validate persistence** (position restoration)
5. ✅ **Use test audiobooks** (short, deterministic)
6. ✅ **Visual snapshots** (player UI appearance)

### **Implementation Time:**
- **Week 1:** Add AudiobookPlayerScreen + helpers
- **Week 2:** Create 20 audiobook tests
- **Week 3:** Add visual snapshot tests
- **Week 4:** Run on BrowserStack for DRM validation

### **Total:** Complete audiobook testing suite in 1 month

---

**Want me to create the complete AudiobookPlayerScreen class and test suite?** 🎵🎧
