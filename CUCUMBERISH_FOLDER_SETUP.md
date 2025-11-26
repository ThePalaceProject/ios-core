# Cucumberish Folder Setup - The Proper Way

**Why you're getting "NSBundle (null) initWithPath failed"**

---

## 🔍 **The Problem:**

Cucumberish requires .feature files to be in a **folder reference** (blue folder), not as individual file copies.

**What you have:**
```
Copy Bundle Resources:
  MyBooks.feature (file)
  AudiobookLyrasis.feature (file)
  ... (24 individual files)
```

**What Cucumberish needs:**
```
Copy Bundle Resources:
  Features/ (folder reference - blue folder)
    ├── MyBooks.feature
    ├── AudiobookLyrasis.feature
    └── ... (files inside folder)
```

---

## ✅ **The Proper Fix (In Xcode - 5 minutes):**

### **Step 1: Remove Individual Files**

1. PalaceUITests target → **Build Phases**
2. **Copy Bundle Resources** section
3. Select ALL .feature files (should be ~24 files)
4. Click **− (minus)** button to remove them
5. They'll still be in your project, just not copied individually

### **Step 2: Add as Folder Reference**

1. In **Project Navigator** (left sidebar)
2. Find your `PalaceUITests/Features/` folder
3. Delete the Features group if it exists (right-click → Delete → Remove Reference)

4. **Right-click** `PalaceUITests` folder
5. **Add Files to "PalaceUITests"...**
6. Navigate to `/Users/mauricework/PalaceProject/ios-core/PalaceUITests/`
7. Select the **Features folder** (the actual folder, not files inside)
8. **CRITICAL:** In the dialog, select:
   - ⭕ **Create folder references** (NOT "Create groups")
   - ✅ **Add to targets:** PalaceUITests
9. Click **Add**

### **Step 3: Verify**

In **Project Navigator**, you should now see:
```
PalaceUITests
  └── Features (BLUE folder icon - folder reference)
      ├── MyBooks.feature
      ├── AudiobookLyrasis.feature
      └── ...
```

NOT a white/gray folder (that's a group, won't work!)

In **Build Phases → Copy Bundle Resources**:
```
Features (folder reference)
```

NOT individual files!

---

## 🎯 **Then Update Code:**

Change back to:
```swift
Cucumberish.executeFeatures(
  inDirectory: "Features",  // Now it will find the folder!
  from: bundle,
  ...
)
```

---

## 🚀 **Then Test:**

```
⌘B (Build)
⌘U (Run)
```

**Should see:**
```
✅ Found Features directory
Scenario: MyBooks... EXECUTING
```

**Your 197 scenarios will run!**

---

## 📝 **Key Difference:**

**Folder Reference (Blue):** ✅ Creates bundle/Features/
**Group (Gray/White):** ❌ Just organizational, doesn't affect bundle structure

Cucumberish REQUIRES folder references!

---

**This is the proper fix!** Follow these steps and Cucumberish will work! 🎯

