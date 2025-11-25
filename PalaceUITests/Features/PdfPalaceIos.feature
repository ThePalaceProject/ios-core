Feature: Read PDF in Palace Bookshelf on IOS

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open search modal
      And Search for 'Pharo by Example 5.0' and save bookName as 'bookNameInfo'
      And Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open EBOOK book with READ action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened

  @tier2 @exclude_android
  Scenario: Navigate by Page
    Then Save page number as 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Go to next page on reader pdf screen
    Then Page number increased by 1 from 'pageInfo' on pdf reader screen in "Lyrasis Reads"
    When Save page number as 'pageInfo2' on pdf reader screen in "Lyrasis Reads"
      And Go to previous page on reader pdf screen
    Then Page number decreased by 1 from 'pageInfo2' on pdf reader screen in "Lyrasis Reads"

  @tier2 @exclude_android
  Scenario: Open book to last page read
    When Swipe pdf page forward from 4 to 6 times on reader pdf screen
      And Save page number as 'pageNumber' on pdf reader screen in "Lyrasis Reads"
      And Return to previous screen for epub and pdf
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And Page number is equal to 'pageNumber' on pdf reader screen in "Lyrasis Reads"
    When Restart app
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click READ action button on Book details screen
    Then Reader pdf screen is opened
      And Page number is equal to 'pageNumber' on pdf reader screen in "Lyrasis Reads"

  @tier2 @exclude_android
  Scenario: Navigate by Thumbnails
    When Open TOC on pdf reader screen
    Then There are content list with thumbnails and chapter content on pdf toc screen
    When Open 2 thumbnail and save the number as 'pageInfo' on pdf toc screen
    Then Page number is equal to 'pageInfo' on pdf reader screen in "Lyrasis Reads"

  @tier2 @exclude_android
  Scenario: Search Pdf Functionality
    When Open search pdf screen
    Then Search pdf screen is opened
    When Close pdf search screen
    Then Reader pdf screen is opened
    When Open search pdf screen
    Then Search pdf screen is opened
    When Enter 'try' text on search pdf screen
      And Delete text in search line on search pdf screen
    Then Search field is empty on search pdf screen
    When Enter 'try' text on search pdf screen
    Then Found lines should contain 'try' in themselves on search pdf screen
    When Close pdf search screen

  @tier2 @exclude_android
  Scenario: Navigate by Pdf Search Results
    When Open search pdf screen
      And Search for 'try' text on search pdf screen and save word as 'foundText'
      And Open the found text with 'foundText' word and save page number as 'pageNumber' on search pdf screen
    Then Current page number is equal to 'pageNumber' on pdf reader screen

  @tier2 @exclude_android
  Scenario: Navigate by Page slider
    When Swipe pdf page forward from 4 to 6 times on reader pdf screen
      And Save page number as 'pageNumber' on pdf reader screen in "Lyrasis Reads"
      And Slide page slider LEFT on reader pdf screen
    Then The 'pageNumber' saved page number is less than the current page number on the reader pdf screen in "Lyrasis Reads"
    When Save page number as 'pageNumber' on pdf reader screen in "Lyrasis Reads"
      And Slide page slider RIGHT on reader pdf screen
    Then The 'pageNumber' saved page number is greater than the current page number on the reader pdf screen in "Lyrasis Reads"

  @tier2 @exclude_android
  Scenario: Navigate by pdf bookmarks
    When Open bookmarks pdf screen
    Then Bookmarks pdf screen is opened
      And There are no bookmarks on bookmarks pdf screen
    When Close toc bookmarks pdf screen
      And Go to next page on reader pdf screen
      And Add bookmark on reader pdf screen
      And Save page number as 'pageNumberInfo' on pdf reader screen in "Lyrasis Reads"
      And Go to next page on reader pdf screen
      And Add bookmark on reader pdf screen
      And Save page number as 'pageNumberInfo2' on pdf reader screen in "Lyrasis Reads"
      And Go to next page on reader pdf screen
      And Add bookmark on reader pdf screen
      And Open bookmarks pdf screen
    Then Amount of bookmarks is 3 on bookmarks pdf screen
    When Open the 1 bookmark on bookmarks pdf screen
    Then Page number is equal to 'pageNumberInfo' on pdf reader screen in "Lyrasis Reads"

  @tier2 @exclude_android
  Scenario: Check table of contents
    When Open TOC on pdf reader screen
      And Open text chapter content on pdf toc screen
    Then Text chapter content is opened on pdf toc screen
    When Open content with thumbnails on pdf toc screen
    Then Thumbnails of the book pages are displayed

  @tier2 @exclude_android
  Scenario: Navigate by Chapters
    When Open TOC on pdf reader screen
      And Open text chapter content on pdf toc screen
      And Open the 4 chapter and save the number as 'pageNumberInfo' on pdf toc screen
    Then Current page number is equal to 'pageNumberInfo' on pdf reader screen