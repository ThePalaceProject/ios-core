Feature: Feed

  @tier2 @exclude_ios
  Scenario: Update Bookshelf List (ANDROID)
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open categories by chain and chain starts from CategoryScreen:
        | Big Ten Open Books |
      And Click GET action button on the first EBOOK book on catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
      And Amount of books is equal to 1 on books screen
    When Refresh list of books on books screen
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
      And Amount of books is equal to 1 on books screen

  @tier2 @exclude_android
  Scenario: Update Bookshelf List (IOS)
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Open categories by chain and chain starts from CategoryScreen:
      | Big Ten Open Books |
      And Click GET action button on the first EBOOK book on catalog books screen and save book as 'bookInfo'
      And Open Books
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
      And Amount of books is equal to 1 on books screen
    When Refresh list of books on books screen
    Then EBOOK book with READ action button and 'bookInfo' bookInfo is present on books screen
      And Amount of books is equal to 1 on books screen