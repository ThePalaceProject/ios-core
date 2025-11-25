Feature: Check of View Sample in A1QA Test Library

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
      And Settings screen is opened
    When Turn on test mode
      And Enable hidden libraries
      And Open Catalog
      And Add "A1QA Test Library" account by the logo
    Then Library "A1QA Test Library" is opened on Catalog screen
    When Open Catalog
      And Switch to "Audiobooks" catalog tab
    Then Catalog screen is opened

  @tier2
  Scenario: Audiobooks: Play Sample: Sample player: Perform check of the elements
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click PLAY_SAMPLE action button on Book details screen
    Then Check that Sample player screen of 'bookNameInfo' book contains all necessary elements

  @smoke @exclude_android
  Scenario: iOS: Audiobooks: Play Sample: Play Sample button: Perform check of activating and deactivating sample player
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click PLAY_SAMPLE action button on Book details screen
    Then Sample player screen is displayed on Books details screen
      And Pause button is displayed on Sample player screen
    When Click PLAY_SAMPLE action button on Book details screen
    Then Play button is displayed on Sample player screen

  @smoke
  Scenario: Audiobooks: Play Sample: Sample player: Perform check of pause and play buttons
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click PLAY_SAMPLE action button on Book details screen
    Then Sample player screen is displayed on Books details screen
    When Tap pause button on Sample player screen
    Then Play button is displayed on Sample player screen
    When Tap play button on Sample player screen
    Then Pause button is displayed on Sample player screen

  @smoke @exclude_ios
  Scenario: Android: Audiobooks: Play Sample: Sample player: Perform check of Back button
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click PLAY_SAMPLE action button on Book details screen
    Then Sample player screen is displayed on Books details screen
    When Tap Back button on Sample played screen
    Then Book 'bookNameInfo' is opened on book details screen