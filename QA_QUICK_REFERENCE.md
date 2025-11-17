# Palace iOS Testing - QA Quick Reference

**One-page summary: What QA needs to know**

---

## 🎯 Bottom Line

**QA can KEEP writing Gherkin** → **Cucumberish runs it directly** → **Tests run 70% faster**

---

## ✍️ What You Write (Gherkin - Familiar!)

```gherkin
Feature: Book Download
  Scenario: Download a book
    Given I am on the Catalog screen
    When I search for "Alice in Wonderland"
    And I tap the GET button
    Then the book should download
```

---

## 🤖 What Happens (Automatic!)

**No conversion needed!** Cucumberish **runs your .feature files directly** as XCTests.

Developers create step definitions once (in Swift):
```swift
// Developer writes this once:
Given("I am on the Catalog screen") { _, _ in
    let catalog = CatalogScreen(app: XCUIApplication())
    XCTAssertTrue(catalog.isDisplayed())
}

When("I search for \"(.*)\"") { args, _ in
    let searchTerm = args![0]
    search.enterSearchText(searchTerm)
}
```

**Then your .feature files just run!** No conversion step.

---

## 🔄 Your New Workflow (3 Steps - Simpler!)

```bash
# 1. Write scenario (familiar Gherkin)
vim features/my-test.feature

# 2. Submit PR
git add features/my-test.feature
git commit -m "Add my test"
git push

# 3. Tests run automatically in CI/CD
# (That's it! No conversion step needed)
```

---

## ✅ What Stays the Same

- ✅ Write in Gherkin (.feature files)
- ✅ Think in Given/When/Then
- ✅ Focus on user flows
- ✅ No coding required
- ✅ Same test format as today

---

## 🔄 What Changes

- 🔄 Framework: Cucumberish (not Java/Cucumber)
- 🔄 Platform: XCTest (not Appium)
- 🔄 Tests run on simulators (faster, free)
- 🔄 BrowserStack only for DRM tests (cost savings)

---

## ⏱️ Timeline

- **Weeks 1-2:** ✅ Swift/XCTest framework built (done)
- **Week 3:** 🔄 Integrate Cucumberish + snapshot testing
- **Week 4:** 🔄 Create Palace step definitions
- **Week 5:** 🔄 QA training on Cucumberish
- **Week 6:** 🔄 Pilot (20 scenarios)
- **Weeks 7-12:** 🔄 Full migration (400+ scenarios)

---

## 💰 Impact

- **70% faster** tests
- **$6k/year** savings
- **Better reliability**
- **QA keeps ownership**

---

## 📚 Documents to Read

**Start here:** `QA_SUMMARY_FOR_MEETING.md` (10 min read)  
**Detailed:** `QA_TESTING_STRATEGY.md` (30 min read)  
**Audiobooks:** `AUDIOBOOK_TESTING_STRATEGY.md`  
**Visual:** `VISUAL_TESTING_STRATEGY.md`  

---

## 🎓 Training (Week 5)

- **Day 1:** Cucumberish overview & demo
- **Day 2:** Writing .feature files for Palace
- **Day 3:** Available step definitions
- **Day 4:** Running tests & reviewing results
- **Day 5:** Practice (write 5 real tests)

---

## ❓ Common Questions

**Q: Do I need to learn Swift?**  
**A:** No! You write Gherkin, Cucumberish runs it.

**Q: Can I keep writing Gherkin?**  
**A:** YES! Write .feature files like always.

**Q: What about BrowserStack?**  
**A:** Still used for DRM tests (optimized).

**Q: What's Cucumberish?**  
**A:** iOS Gherkin framework - runs .feature files directly.

---

## 📞 Questions?

**Slack:** `#ios-testing`  
**Email:** ios-team@palaceproject.org  
**Docs:** See above

---

*Quick Reference - Print & Keep Handy!*

