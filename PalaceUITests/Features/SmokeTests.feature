Feature: Smoke Tests
  Critical smoke tests that verify core app functionality
  
  Background:
    Given the app should launch
    And the app should be ready
  
  Scenario: App launches and tabs are accessible
    Given I am on the Catalog screen
    When I navigate to My Books
    Then I should be on the My Books screen
    When I navigate to Settings
    Then I should be on the Settings screen
    When I navigate to Catalog
    Then I should be on the Catalog screen
  
  Scenario: Search for a book
    Given I am on the Catalog screen
    When I search for "Alice"
    Then I should see search results
  
  Scenario: Download a book
    Given I am on the Catalog screen
    When I search for "Alice in Wonderland"
    And I tap the first result
    And I take a screenshot named "book-detail"
    And I tap the GET button
    And I wait for download to complete
    Then I should see the READ button
    And I take a screenshot named "book-downloaded"
  
  Scenario: Book appears in My Books
    Given I am on the Catalog screen
    When I search for "Alice"
    And I tap the first result
    And I download the book
    When I navigate to My Books
    Then the book should be in My Books
  
  Scenario: Delete a book
    Given I am on the Catalog screen
    When I search for "Alice"
    And I tap the first result
    And I tap the GET button
    And I wait for download to complete
    And I tap the DELETE button
    And I confirm deletion
    Then I should see the GET button
