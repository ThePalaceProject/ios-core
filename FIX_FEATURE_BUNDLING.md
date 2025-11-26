# Fix .feature File Bundling for Cucumberish

**The files are in bundle but Cucumberish can't find them properly**

---

## 🔍 **The Problem:**

Console shows:
  ✅ "Bundle contains: 24 .feature files"
  ❌ "NSBundle (null) initWithPath failed" (44 times)

This means:
  - Files are copied to bundle ✅
  - But NOT in the folder structure Cucumberish expects ❌
  - Cucumberish needs: bundle/Features/*.feature
  - You have: bundle/*.feature (flat)

---

## ✅ **Solution: Create Features Folder in Bundle**

### **In Xcode:**

**Step 1: Remove Current .feature Files from Copy Bundle Resources**

1. PalaceUITests target → Build Phases
2. Copy Bundle Resources
3. Select all .feature files
4. Click − (minus) to remove them

**Step 2: Add with Folder Structure**

1. In Project Navigator, make sure your .feature files are in a **group** called "Features" (blue folder icon)
2. If not, create group:
   - Right-click PalaceUITests
   - New Group → Name it "Features"
   - Drag all .feature files into this group

3. Build Phases → Copy Bundle Resources → +
4. THIS TIME: Click "Add Other..."
5. Navigate to PalaceUITests/Features/
6. Important: Check ✅ "Create folder references" (NOT "Create groups")
7. Select the Features folder itself
8. Click "Add"

**Step 3: Verify**

In Copy Bundle Resources, you should see:
```
Features (folder - blue icon)
  ├── MyBooks.feature
  ├── AudiobookLyrasis.feature
  └── ... (all files)
```

NOT:
```
MyBooks.feature (individual files - white icons)
AudiobookLyrasis.feature
...
```

---

## 🎯 **Alternative: Use Different API**

If folder bundling doesn't work, modify Cucumberish call to use explicit file paths.

I can help with that if folder approach fails!

---

**Try the folder reference approach first!**
