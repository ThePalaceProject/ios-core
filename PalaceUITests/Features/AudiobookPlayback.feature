Feature: Audiobook Playback
  Validate audiobook playback functionality
  
  Scenario: Play an audiobook
    Given I am on the Catalog screen
    When I search for "audiobook"
    And I tap the first result
    And I download the book
    And I tap the LISTEN button
    When I tap the play button
    And I wait for 5 seconds
    Then playback time should advance
  
  Scenario: Skip forward and backward
    Given I am on the Catalog screen
    When I search for "audiobook"
    And I tap the first result
    And I download the book
    And I tap the LISTEN button
    And I tap the play button
    When I skip forward 30 seconds
    And I wait for 1 second
    When I skip backward 30 seconds
    And I wait for 1 second
    Then playback time should advance
  
  Scenario: Change playback speed
    Given I am on the Catalog screen
    When I search for "audiobook"
    And I tap the first result
    And I download the book
    And I tap the LISTEN button
    And I tap the play button
    When I set playback speed to "1.5x"
    And I wait for 10 seconds
    Then playback time should advance
