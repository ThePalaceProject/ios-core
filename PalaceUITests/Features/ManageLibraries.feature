Feature: Manage Libraries

  @tier2
  Scenario: Settings: Add library: general checks
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open Settings
      And Open Libraries on Settings screen
    Then Button Add Library is displayed on libraries screen
    When Click Add library button on libraries screen
    Then Add library screen is opened

  @tier2
  Scenario: Navigate by Tutorial
    Then Tutorial screen is opened
      And Each tutorial page can be opened on Tutorial screen and close tutorial screen
      And Welcome screen is opened

  @tier2
  Scenario: Settings: Add library
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Get names of books on screen and save them as 'nameOfBooks'
      And Add 'Lyrasis Reads' library in Libraries screen
    Then Category names are loaded on Catalog screen
      And List of books on screen is not equal to list of books saved as 'nameOfBooks'

  @tier2
  Scenario: Settings: Add Library: Check of the added libraries sorting
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Libraries screen
    When Add libraries through settings:
      | Lyrasis Reads            |
      | Plumas County Library    |
      | Escondido Public Library |
      | Granby Public Library    |
      | Victorville City Library |
      And Open Settings
      And Open Libraries on Settings screen
    Then Libraries are sorted in alphabetical order on libraries screen
    When Click to 'Escondido Public Library' and save library name as 'libraryInfo' on libraries screen
    Then The screen with settings for 'libraryInfo' library is opened

  @tier2
  Scenario: Settings: Libraries: Remove library
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Libraries screen
    When Add 'Palace Bookshelf' library in Libraries screen
      And Switch to 'Lyrasis Reads' from side menu
      And Remove 'Palace Bookshelf' library
    Then Library 'Palace Bookshelf' is not present on Libraries screen

  @tier2 @exclude_ios
  Scenario: Switch library bookshelf (ANDROID)
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Libraries screen
    When Add 'Lyrasis Reads' library in Libraries screen
      And Open Catalog
      And Switch to 'Palace Bookshelf' from side menu
      And Open categories by chain and chain starts from CategoryScreen:
      | DPLA Publications |
      And Click GET action button on the first EBOOK book on catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open Catalog
      And Return to previous screen for epub and pdf
      And Switch to 'Lyrasis Reads' from side menu
      And Open Books
    Then There are not books on books screen

  @tier2 @exclude_android
  Scenario: Switch library bookshelf (IOS)
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Libraries screen
    When Add 'Lyrasis Reads' library in Libraries screen
      And Open Catalog
      And Switch to 'Palace Bookshelf' from side menu
      And Open categories by chain and chain starts from CategoryScreen:
      | Fiction            |
      | Historical Fiction |
      And Click GET action button on the first EBOOK book on catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open Catalog
      And Return to previous screen for epub and pdf
      And Switch to 'Lyrasis Reads' from side menu
      And Open Books
    Then There are not books on books screen

  @logout @tier2
  Scenario: Store library card
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Libraries screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Open library 'Lyrasis Reads'
      And Click the log out button on the account screen
    Then Logout is performed successfully

  @tier2
  Scenario: Logo: Add library: Check of adding a library
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Libraries screen
    When Open Catalog
      And Add 'Lyrasis Reads' account by the logo
    Then Category names are loaded on Catalog screen

  @tier2
  Scenario: Logo: Add Library: Check of sorting libraries
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Add libraries by the logo:
      | Lyrasis Reads            |
      | Plumas County Library    |
      | Escondido Public Library |
      | Granby Public Library    |
      | Victorville City Library |
      And Save 6 amount as 'amountKey'
    And Tap the logo on catalog screen
    Then The sorting of 'amountKey' libraries is alphabetical on find your library screen
    When Tap cancel button on find your library screen
    Then Category names are loaded on Catalog screen

  @tier2
  Scenario: Logo: Switch library
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Add libraries by the logo:
      | Lyrasis Reads            |
      | Plumas County Library    |
      | Escondido Public Library |
      And Tap the logo on catalog screen
      And Choose 'Palace Bookshelf' library on find your library screen
    Then Category names are loaded on Catalog screen

  @smoke
  Scenario: Lyrasis Reads link: Make sure that there is a redirection to the Lyrasis Reads library with the list of books
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
      And Category names are loaded on Catalog screen