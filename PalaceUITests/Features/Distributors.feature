Feature: Distributors

  Background:
    Given Close tutorial screen
    Then Add library screen is opened

  @logout @returnBooks @tier2
  Scenario Outline: Reserving from Book Detail View in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor '<distributor>' and bookType '<bookType>' and save as 'bookNameInfo'
      And Switch to '<tabName>' catalog tab
      And Open <bookType> book with RESERVE action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click RESERVE action button on Book details screen
    Then Check that book contains REMOVE action button on Book details screen

    Scenarios:
      | distributor        | bookType  | tabName    |
      | Bibliotheca        | EBOOK     | eBooks     |
      | Bibliotheca        | AUDIOBOOK | Audiobooks |
      | Axis 360           | EBOOK     | eBooks     |
      | Axis 360           | AUDIOBOOK | Audiobooks |
      | Palace Marketplace | EBOOK     | eBooks     |
      | Palace Marketplace | AUDIOBOOK | Audiobooks |

  @logout @returnBooks @tier2
  Scenario Outline: Getting and returning books from Book Detail View in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Open Catalog
      And Open search modal
      And Search 'available' book of distributor '<distributor>' and bookType '<bookType>' and save as 'bookNameInfo'
      And Switch to '<tabName>' catalog tab
      And Open <bookType> book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains <buttonBookDetailsView> action button on Book details screen
    When Click RETURN action button on Book details screen
    Then Check that book contains GET action button on Book details screen
    When Click GET action button on Book details screen
    Then Check that book contains <buttonBookDetailsView> action button on Book details screen
    When Click <buttonBookDetailsView> action button on Book details screen
      And Wait for 3 seconds
    Then Book 'bookInfo' with <bookType> type is present on epub or pdf or audiobook screen

    Scenarios:
      | distributor        | bookType  | tabName    | buttonBookDetailsView |
      | Bibliotheca        | EBOOK     | eBooks     | READ                  |
      | Bibliotheca        | AUDIOBOOK | Audiobooks | LISTEN                |
      | Axis 360           | EBOOK     | eBooks     | READ                  |
      | Axis 360           | AUDIOBOOK | Audiobooks | LISTEN                |
      | Palace Marketplace | EBOOK     | eBooks     | READ                  |
      | Palace Marketplace | AUDIOBOOK | Audiobooks | LISTEN                |
      | Biblioboard        | EBOOK     | eBooks     | READ                  |
      | Biblioboard        | AUDIOBOOK | Audiobooks | LISTEN                |

  @tier2 @exclude_ios
  Scenario: Getting and returning a book from Book Detail View for Palace Bookshelf (Android)
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open search modal
      And Search for "Jane Eyre" and save bookName as 'bookNameInfo'
      And Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains READ action button on Book details screen
    When Click RETURN action button on Book details screen
    Then Check that book contains GET action button on Book details screen
    When Click GET action button on Book details screen
    Then Check that book contains READ action button on Book details screen
    When Click READ action button on Book details screen
      And Wait for 3 seconds
    Then Book 'bookInfo' with AUDIOBOOK type is present on epub or pdf or audiobook screen

  @tier2 @exclude_android
  Scenario: Getting and returning a book from Book Detail View for Palace Bookshelf (iOS)
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open search modal
      And Search for "Jane Eyre" and save bookName as 'bookNameInfo'
      And Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
    Then Check that book contains READ action button on Book details screen
    When Click DELETE action button on Book details screen
    Then Check that book contains GET action button on Book details screen
    When Click GET action button on Book details screen
    Then Check that book contains READ action button on Book details screen
    When Click READ action button on Book details screen
      And Wait for 3 seconds
    Then Book 'bookInfo' with AUDIOBOOK type is present on epub or pdf or audiobook screen

  @logout @returnBooks @tier2 @exclude_android
  Scenario Outline: Check of canceling the downloading from book details view for Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'available' book of distributor '<distributor>' and bookType '<bookType>' and save as 'bookNameInfo'
      And Switch to '<tabName>' catalog tab
      And Open <bookType> book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button and cancel downloading by click CANCEL button on book detail screen
    Then Check that book contains DOWNLOAD action button on Book details screen
      And Check that book contains RETURN action button on Book details screen

    Scenarios:
      | distributor        | bookType  | tabName    |
      | Bibliotheca        | EBOOK     | eBooks     |
      | Bibliotheca        | AUDIOBOOK | Audiobooks |
      | Palace Marketplace | EBOOK     | eBooks     |
      | Palace Marketplace | AUDIOBOOK | Audiobooks |
      | Axis 360           | EBOOK     | eBooks     |
      | Axis 360           | AUDIOBOOK | Audiobooks |
      | Biblioboard        | EBOOK     | eBooks     |
      | Biblioboard        | AUDIOBOOK | Audiobooks |

  @logout @tier2 @exclude_android
  Scenario: Check of canceling the downloading from book details view for Overdrive
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Turn on test mode
      And Enable hidden libraries
    When Open Catalog
      And Add "A1QA Test Library" account by the logo
    Then Library "A1QA Test Library" is opened on Libraries screen
    When Enter credentials for "A1QA Test Library" library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search for "The Fallen" and save bookName as 'bookNameInfo'
      And Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button and cancel downloading by click CANCEL button on book detail screen
    Then Check that book contains DOWNLOAD action button on Book details screen
      And Check that book contains RETURN action button on Book details screen
    When Click RETURN action button on Book details screen
    Then Check that book contains GET action button on Book details screen