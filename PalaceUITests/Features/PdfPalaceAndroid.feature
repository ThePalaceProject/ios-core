Feature: Read PDF in Palace Bookshelf on Android

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open search modal
      And Search for 'Pharo by Example 5.0' and save bookName as 'bookNameInfo'

  @tier2 @exclude_ios
  Scenario: Check of book title and back button Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And The book name is 'bookNameInfo' on pdf reader screen
    When Close pdf reader by back button
    Then Book "bookInfo" is opened on book details screen

  @tier2 @exclude_ios
  Scenario: Check table of contents Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And There are content list with thumbnails and chapter content on pdf toc screen
    When Return to pdf reader screen from pdf toc screen
    Then PDF toc screen is closed
    When Open TOC on pdf reader screen
      And Open TOC on pdf reader screen
    Then PDF toc screen is closed
    When Open TOC on pdf reader screen
      And Close pdf toc screen by back button
    Then PDF toc screen is closed

  @tier2 @exclude_ios
  Scenario: TOC: Contents with thumbnails: Check of Contents list and navigation Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open content with thumbnails on pdf toc screen
    Then Thumbnails of the book pages are displayed
    When Open random thumbnail and save the number as 'pageInfo' on pdf toc screen in "Palace Bookshelf"
      And Return to pdf reader screen from pdf toc screen
    Then Page number is equal to 'pageInfo' on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: TOC: Contents with text: Check of list of chapters and navigation Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Open text chapter content on pdf toc screen
    Then Text chapter content is opened on pdf toc screen
    When Open random chapter and save the number as 'pageInfo' on pdf toc screen in "Palace Bookshelf"
      And Return to pdf reader screen from pdf toc screen
    Then Page number is equal to 'pageInfo' on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: Check of settings screen and page navigation Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Save the number of the last page as 'lastPageInfo' on pdf reader screen
      And Open pdf settings screen on pdf reader screen
    Then PDF settings screen is opened
      And Vertical scrolling is chosen by default on settings screen
    When Tap Go to last page button on pdf settings screen
    Then Page number is equal to 'lastPageInfo' on pdf reader screen in "Palace Bookshelf"
    When Open pdf settings screen on pdf reader screen
    Then PDF settings screen is opened
    When Tap Go to first page button on pdf settings screen
    Then The first page is opened on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: Settings: Check of Vertical scrolling Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Return to pdf reader screen from pdf toc screen
      And Open pdf settings screen on pdf reader screen
      And Tap Vertical scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Vertical scrolling is chosen on settings screen
      And Spreads options are available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Palace Bookshelf"
      And Scroll page down on pdf reader screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Palace Bookshelf"
    When Save page number as 'pageInfo2' on pdf reader screen in "Palace Bookshelf"
      And Scroll page up on pdf reader screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: Settings: Check of Horizontal scrolling Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Return to pdf reader screen from pdf toc screen
      And Open pdf settings screen on pdf reader screen
      And Tap Horizontal scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Horizontal scrolling is chosen on settings screen
      And Spreads options are not available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Palace Bookshelf"
      And Go to next page on reader pdf screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Palace Bookshelf"
    When Save page number as 'pageInfo2' on pdf reader screen in "Palace Bookshelf"
      And Go to previous page on reader pdf screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: Settings: Check of Wrapped scrolling Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Return to pdf reader screen from pdf toc screen
      And Open pdf settings screen on pdf reader screen
      And Tap Wrapped scrolling on pdf settings screen
      And Open pdf settings screen on pdf reader screen
    Then Wrapped scrolling is chosen on settings screen
      And Spreads options are available on settings screen
    When Open pdf settings screen on pdf reader screen
      And Save page number as 'pageInfo' on pdf reader screen in "Palace Bookshelf"
      And Scroll page down on pdf reader screen
    Then Page number is not equal to 'pageInfo' on pdf reader screen in "Palace Bookshelf"
    When Save page number as 'pageInfo2' on pdf reader screen in "Palace Bookshelf"
      And Scroll page up on pdf reader screen
    Then Page number is not equal to 'pageInfo2' on pdf reader screen in "Palace Bookshelf"

  @tier2 @exclude_ios
  Scenario: Open book to last page read Palace
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
    When Return to pdf reader screen from pdf toc screen
      And Swipe pdf page down from 10 to 20 times on reader pdf screen
      And Save page number as 'pageNumber' on pdf reader screen in "Palace Bookshelf"
      And Return to previous screen for epub and pdf
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And Page number is equal to 'pageNumber' on pdf reader screen in "Palace Bookshelf"
    When Restart app
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And Page number is equal to 'pageNumber' on pdf reader screen in "Palace Bookshelf"