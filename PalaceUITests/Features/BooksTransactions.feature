Feature: Books transactions in Palace Bookshelf

  Background:
    Given Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open search modal
      And Search for 'Flower Fables' and save bookName as 'bookNameInfo'

  @tier2 @exclude_ios
  Scenario: Check of GET button (Android)
    Then Check that book 'bookNameInfo' contains GET action button on catalog book screen
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then Check that book 'bookNameInfo' contains READ action button on catalog book screen
      And Check that book 'bookNameInfo' contains RETURN action button on catalog book screen

  @tier2 @exclude_android
  Scenario: Check of GET button (iOS)
    Then Check that book 'bookNameInfo' contains GET action button on catalog book screen
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then Check that book 'bookNameInfo' contains READ action button on catalog book screen
      And Check that book 'bookNameInfo' contains DELETE action button on catalog book screen

  @tier2 @exclude_ios
  Scenario: Get a book from Subcategory List View and Return from Subcategory List View (ANDROID)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click RETURN action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is present on Catalog books screen

  @tier2 @exclude_android
  Scenario: Get a book Subcategory List View and Return from Subcategory List View (IOS)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click DELETE action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is present on Catalog books screen

  @tier2 @exclude_ios
  Scenario: Get a book from Subcategory List View and Read from Subcategory List View (ANDROID)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
      And Click READ action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then 'bookInfo' book is present on epub reader screen

  @tier2 @exclude_android
  Scenario: Get a book from Subcategory List View and Read from Subcategory List View (IOS)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And EBOOK book with READ action button and 'bookInfo' bookInfo is present on Catalog books screen
      And Click READ action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then 'bookInfo' book is present on epub reader screen

  @tier2 @exclude_ios
  Scenario: Get a book from Subcategory List View and Return from Books (ANDROID)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click RETURN action button on Book details screen
      And Open Books
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is not present on books screen

  @tier2 @exclude_android
  Scenario: Get a book from Subcategory List View and Return from Books (IOS)
    When Click GET action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click DELETE action button on Book details screen
      And Open Books
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is not present on books screen

  @tier2 @exclude_ios
  Scenario: Get a book from Book Detail View and Return from Books (ANDROID)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click RETURN action button on Book details screen
      And Open Books
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is not present on books screen

  @tier2 @exclude_android
  Scenario: Get a book from Book Detail View and Return from Books (IOS)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
    When Open EBOOK book with READ action button and 'bookInfo' bookInfo on books screen
      And Click DELETE action button on Book details screen
      And Open Books
    Then EBOOK book with GET action button and 'bookInfo' bookInfo is not present on books screen

  @tier2 @exclude_ios
  Scenario: Get a book from Book Detail View and Return from Book Detail View (ANDROID)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Click RETURN action button on Book details screen
    Then Check that book contains GET action button on Book details screen

  @tier2 @exclude_android
  Scenario: Get a book from Book Detail View and Return from Book Detail View (IOS)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Click DELETE action button on Book details screen
    Then Check that book contains GET action button on Book details screen

  @tier2 @exclude_ios
  Scenario: Get a book from Book Detail View and Read from Book Detail View (ANDROID)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Click READ action button on Book details screen
    Then 'bookInfo' book is present on epub reader screen

  @tier2 @exclude_android
  Scenario: Get a book from Book Detail View and Read from Book Detail View (IOS)
    When Open EBOOK book with GET action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click GET action button on Book details screen
      And Click READ action button on Book details screen
    Then 'bookInfo' book is present on epub reader screen