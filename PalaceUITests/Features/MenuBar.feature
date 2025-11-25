Feature: Menu Bar module

  Background:
    Given Close tutorial screen
    Then Add library screen is opened

  @tier2
  Scenario Outline: Check of menu bar in Palace Bookshelf
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
      And There is a menu bar at the bottom of the screen
      And There are tabs '<tab1>', '<tab2>' and '<tab3>' at the bottom of the screen

    Scenarios:
      | tab1    | tab2     | tab3     |
      | Catalog | My Books | Settings |

  @tier2
  Scenario: Check of the tabs in Palace Bookshelf
    When Add library "Palace Bookshelf" on Add library screen
    Then Catalog screen is opened
    When Open Books
    Then Books screen is opened
    When Open Settings
    Then Settings screen is opened

  @tier2
  Scenario Outline: Check of menu bar in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And There is a menu bar at the bottom of the screen
      And There are tabs '<tab1>', '<tab2>', '<tab3>' and '<tab4>' at the bottom of the screen

    Scenarios:
      | tab1    | tab2     | tab3         | tab4     |
      | Catalog | My Books | Reservations | Settings |

  @tier2
  Scenario: Check of the tabs in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Catalog screen is opened
    When Open Books
    Then Books screen is opened
    When Open Reservations
    Then Reservations screen is opened
    When Open Settings
    Then Settings screen is opened