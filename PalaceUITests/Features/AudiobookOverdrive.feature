Feature: Audiobooks in A1QA library

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Turn on test mode
      And Enable hidden libraries
      And Open Catalog
      And Add "A1QA Test Library" account by the logo
    Then Library "A1QA Test Library" is opened on Catalog screen
    When Enter credentials for "A1QA Test Library" library
    Then Login is performed successfully
    When Open Catalog
      And Switch to "Audiobooks" catalog tab
    Then Catalog screen is opened

  @logout @returnBooks @tier2
  Scenario: Audiobooks: Open the audiobook at the last open chapter and check time code
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
    When Open toc audiobook screen
      And Open random chapter on toc audiobook screen and save chapter name as 'chapterNameKey'
    Then Audio player screen of book 'bookInfo' is opened
      And Chapter name on audio player screen is equal to 'chapterNameKey' saved chapter name
      And Pause button is present on audio player screen
    When Select "2"X playback speed on playback speed audiobook screen
      And Wait for 3 seconds
      And Tap pause button on audio player screen
    Then Play button is present on audio player screen
    When Save book play time as 'timeAhead' on audio player screen
      And Return to previous screen from audio player screen
      And Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And Chapter name on audio player screen is equal to 'chapterNameKey' saved chapter name
      And Play time is the same with 'timeAhead' play time before restart on books detail screen
    When Open toc audiobook screen
      And Open the 4 chapter on toc audiobook screen and save the chapter name as 'chapterNameKey2'
    Then Audio player screen of book 'bookInfo' is opened
    When Wait for 3 seconds
      And Tap pause button on audio player screen
    Then Play button is present on audio player screen
    When Save book play time as 'timeAhead' on audio player screen
      And Restart app
      And Open Books
      And Open AUDIOBOOK book with LISTEN action button and 'bookInfo' bookInfo on books screen
      And Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And Chapter name on audio player screen is equal to 'chapterNameKey2' saved chapter name
      And Play time is the same with 'timeAhead' play time before restart on books detail screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen


  @logout @returnBooks @tier2
  Scenario: Audiobooks: Navigate by Audiobook
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
    When Tap play button on audio player screen
    Then Pause button is present on audio player screen
    When Tap pause button on audio player screen
    Then Play button is present on audio player screen
      And Book is not playing on audio player screen
    When Save book play time as 'timeAhead' on audio player screen
      And Save chapter time as 'chapterTimeKey' on audio player screen
      And Skip ahead 30 seconds on audio player screen
      And Tap pause button on audio player screen
    Then Play button is present on audio player screen
      And Playback has been moved forward by 30 seconds from 'timeAhead' and 'chapterTimeKey' seconds on audio player screen
    When Save book play time as 'timeBehind' on audio player screen
      And Skip behind 30 seconds on audio player screen
      And Tap pause button on audio player screen
    Then Play button is present on audio player screen
      And Playback has been moved behind by 30 seconds from 'timeBehind' and 'chapterTimeKey' seconds on audio player screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen

  @logout @returnBooks @tier2 @exclude_android
  Scenario: Audiobooks: Check of line for time remaining
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And Line for time remaining is displayed on audio player screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen

  @logout @returnBooks @tier2
  Scenario: Audiobooks: Check of switching to the next chapter
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
    When Open toc audiobook screen
      And Open the 1 chapter on toc audiobook screen and save the chapter name as 'chapterName' and chapter number as 'chapterNumber'
      And Select "2"X playback speed on playback speed audiobook screen
      And Listen a chapter on audio player screen
    Then Next chapter play automatically and chapter name is not 'chapterName' on audio player screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen

  @logout @returnBooks @tier2
  Scenario: Audiobooks: Check closing playback speed and sleep timer
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And The speed by default is "1.0"X
    When Open playback speed on audio player screen
      And Close playback speed screen
    Then Play button is present on audio player screen
    When Set END_OF_CHAPTER sleep timer on sleep timer audiobook screen
    Then Sleep timer is set to endOfChapter on audio player screen
    When Open sleep timer on audio player screen
      And Close sleep timer screen
    Then Play button is present on audio player screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen

  @logout @returnBooks @tier2
  Scenario Outline: Audiobooks: Playback speed: Check of playback speed
    When Get AUDIOBOOK book from "OverDrive" category and save it as 'bookNameInfo'
      And Open AUDIOBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains LISTEN action button on Book details screen
    When Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
    When Select "<speed>"X playback speed on playback speed audiobook screen
    Then Current playback speed value is <speed>X on audio player screen
    When Return to previous screen from audio player screen
      And Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And Current playback speed value is <speed>X on audio player screen
    When Restart app
      And Open Books
      And Open AUDIOBOOK book with LISTEN action button and 'bookInfo' bookInfo on books screen
      And Click LISTEN action button on Book details screen
    Then Audio player screen of book 'bookInfo' is opened
      And Current playback speed value is <speed>X on audio player screen
    When Tap play button on audio player screen
      And Save book play time as 'timeAhead' on audio player screen
      And Save chapter time as 'chapterTimeKey' on audio player screen
      And Wait for <secondsForWaiting> seconds
    Then Playback has been moved forward by <moveForwardSeconds> seconds from 'timeAhead' and 'chapterTimeKey' seconds on audio player screen
    When Return to previous screen for epub and pdf
      And Click RETURN action button on Book details screen

    Scenarios:
      | speed | secondsForWaiting | moveForwardSeconds |
      | 0.75  | 8                 | 6                  |
      | 1.25  | 8                 | 10                 |
      | 1.50  | 6                 | 9                  |
      | 2     | 5                 | 10                 |