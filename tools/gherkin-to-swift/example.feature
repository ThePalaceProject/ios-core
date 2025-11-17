Feature: Book Download and Reading
  As a Palace user
  I want to download and read books
  So I can enjoy content offline

  Background:
    Given I am on the Catalog screen

  Scenario: Download an EPUB book
    When I search for "Alice in Wonderland"
    And I tap the first result
    And I tap the GET button
    And I wait for download to complete
    Then I should see the READ button

  Scenario: Read a downloaded book
    Given I have a downloaded book
    When I navigate to My Books
    And I tap the first book
    And I tap the READ button
    Then the book should open

  Scenario Outline: Download different book formats
    When I search for "<book_title>"
    And I tap the GET button
    And I wait for download to complete
    Then I should see the <action_button> button
    
    Examples:
      | book_title        | action_button |
      | Alice             | READ          |
      | Pride Prejudice   | LISTEN        |
      | Metamorphosis     | READ          |

