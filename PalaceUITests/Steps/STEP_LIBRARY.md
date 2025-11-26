# Palace Cucumberish Step Library

**Complete reference of all supported Gherkin steps for QA**

---

## 🧭 Navigation Steps

```gherkin
Given I am on the Catalog screen
Given I am on the My Books screen
Given I am on the Settings screen
Given I am on the Holds screen

When I navigate to Catalog
When I navigate to My Books
When I tap the back button

Then I should be on the Catalog screen
```

---

## 🔍 Search Steps

```gherkin
When I search for "Alice in Wonderland"
When I tap the first result
Then I should see search results
```

---

## 📖 Book Action Steps

```gherkin
When I tap the GET button
When I tap the READ button
When I tap the LISTEN button
When I tap the DELETE button
When I confirm deletion
When I download the book
When I wait for download to complete

Then I should see the GET button
Then I should see the READ button
Then I should see the LISTEN button
Then the book should download
Then the book should be in My Books
```

---

## 🎵 Audiobook Steps

```gherkin
When I tap the play button
When I skip forward 30 seconds
When I skip backward 30 seconds
When I set playback speed to "1.5x"
When I open the table of contents
When I select chapter 2

Then playback time should advance
Then I should be on chapter 2
```

---

## ✅ Assertion Steps

```gherkin
Then I should see "Welcome"
Then the app should launch
Then the app should be ready
Then the library logo should be displayed

And I wait 5 seconds
And I take a screenshot
And I take a screenshot named "my-screenshot"
```

---

## 📝 Example Feature

```gherkin
Feature: Book Download

  Scenario: Download and read a book
    Given I am on the Catalog screen
    When I search for "Alice"
    And I tap the first result
    And I tap the GET button
    And I wait for download to complete
    Then I should see the READ button
```

---

*For complete documentation, see CUCUMBERISH_APPROACH.md*
