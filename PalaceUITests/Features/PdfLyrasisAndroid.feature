Feature: Read PDF in Lyrasis Reads on Android

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Check of book title
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And The book name is 'bookNameInfo' on pdf reader screen

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Check of settings screen and page navigation in Lyrasis
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Save the number of the last page as 'lastPageInfo' on pdf reader screen
      And Open pdf settings screen on pdf reader screen
    When Tap Go to last page button on pdf settings screen
    Then Page number is equal to 'lastPageInfo' on pdf reader screen in "Lyrasis Reads"
    When Open pdf settings screen on pdf reader screen
    Then PDF settings screen is opened
    When Tap Go to first page button on pdf settings screen
    Then The first page is opened on pdf reader screen in "Lyrasis Reads"

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Settings: Check of Vertical scrolling in Lyrasis
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open pdf settings screen on pdf reader screen
      And Tap Vertical scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Vertical scrolling is chosen on settings screen
      And Spreads options are available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Lyrasis Reads"
      And Scroll page down on pdf reader screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Save page number as 'pageInfo2' on pdf reader screen in "Lyrasis Reads"
      And Scroll page up on pdf reader screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Lyrasis Reads"

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Settings: Check of Horizontal scrolling in Lyrasis
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open pdf settings screen on pdf reader screen
      And Tap Horizontal scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Horizontal scrolling is chosen on settings screen
      And Spreads options are not available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Lyrasis Reads"
      And Go to next page on reader pdf screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Save page number as 'pageInfo2' on pdf reader screen in "Lyrasis Reads"
      And Go to previous page on reader pdf screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Lyrasis Reads"

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Settings: Check of Wrapped scrolling in Lyrasis
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open pdf settings screen on pdf reader screen
      And Tap Wrapped scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Wrapped scrolling is chosen on settings screen
      And Spreads options are available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Lyrasis Reads"
      And Go to next page on reader pdf screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Save page number as 'pageInfo2' on pdf reader screen in "Lyrasis Reads"
      And Go to previous page on reader pdf screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Lyrasis Reads"

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Table of contents: Perform check of navigation of TOC button
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open TOC on pdf reader screen
    Then There are content list with thumbnails and chapter content on pdf toc screen
    When Return to pdf reader screen from pdf toc screen
    Then PDF toc screen is closed
    When Open TOC on pdf reader screen
      And Open TOC on pdf reader screen
    Then PDF toc screen is closed
    When Open TOC on pdf reader screen
      And Close pdf toc screen by back button
    Then PDF toc screen is closed

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Perform check of Settings
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open pdf settings screen on pdf reader screen
    Then PDF settings screen is opened

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Perform check of scrolling by default (down and up)
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open pdf settings screen on pdf reader screen
      Then Vertical scrolling is chosen by default on settings screen
    When Open pdf settings screen on pdf reader screen
      And Scroll page down on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Lyrasis Reads"
      And Scroll page down on pdf reader screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Save page number as 'pageInfo2' on pdf reader screen in "Lyrasis Reads"
      And Scroll page up on pdf reader screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Lyrasis Reads"

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Table of contents: Perform check of navigation
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open TOC on pdf reader screen
    Then There are content list with thumbnails and chapter content on pdf toc screen
    When Open text chapter content on pdf toc screen
    Then Text chapter content is opened on pdf toc screen
    When Open content with thumbnails on pdf toc screen
    Then Thumbnails of the book pages are displayed

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Perform check of back button
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Close pdf reader by back button
    Then Book "bookInfo" is opened on book details screen

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Table of contents: Contents with thumbnails: Perform check of navigation
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open TOC on pdf reader screen
      And Open content with thumbnails on pdf toc screen
    Then Thumbnails of the book pages are displayed
    When Open random thumbnail and save the number as 'pageInfo' on pdf toc screen in "Lyrasis Reads"
      And Return to pdf reader screen from pdf toc screen
    Then Page number is equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"

  @smoke @logout @returnBooks @exclude_ios
  Scenario: Android: Read pdfs: Table of contents: Chapter content: Perform check of navigation
    When Open search modal
      And Search 'available' book of distributor 'Biblioboard' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open TOC on pdf reader screen
      And Open text chapter content on pdf toc screen
    Then Text chapter content is opened on pdf toc screen
    When Open random chapter and save the number as 'pageInfo' on pdf toc screen in "Lyrasis Reads"
      And Return to pdf reader screen from pdf toc screen
    Then Page number is equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"