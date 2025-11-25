Feature: Search module

  @tier1
  Scenario: Find a library and delete it
    When Close tutorial screen
      And Type 'Brookfield Library' library and save name as 'libraryName' on Add library screen
    Then Library 'libraryName' is displayed on Add library screen
    When Clear search field on Add library screen
    Then Search field is empty on Add library screen

  @tier2
  Scenario Outline: Check that library name contains one or more entered latin letters
    When Close tutorial screen
      And Close welcome screen
      And Type word <word> and save as 'info' on Add library screen
    Then Libraries contain word 'info' on Add library screen

    Scenarios:
      |word    |
      |book    |
      |F       |
      |lyrasis |
      |LYRASIS |
      |lYrAsIs |

  @tier2
  Scenario Outline: Enter invalid data
    When Close tutorial screen
      And Close welcome screen
      And Type word <data> and save as 'data' on Add library screen
    Then Search result is empty on Add library screen

    Scenarios:
      |data                                 |
      |книга                                |
      |9822                                 |
      |<font color=red>Red text</font>      |
      |<script>alert(‘hello world’)</script>|
      |@                                    |
      |$!                                   |

  @tier2
  Scenario Outline: Find a book with name in different font cases in Palace Bookshelf
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open search modal
      And Search for word <word> and save as 'info' on Catalog books screen
    Then The first book has 'info' bookName on Catalog books screen

    Scenarios:
      | word          |
      | el gato negro |
      | EL GATO NEGRO |
      | eL gAto NeGrO |

  @tier2
  Scenario Outline: Enter invalid data in book name in Palace Bookshelf
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open search modal
      And Search for word <data> and save as 'info' on Catalog books screen
    Then There is no results on Catalog books screen

    Scenarios:
      | data                                  |
      | рнл                                   |
      | <font color=red></font>               |
      | <script>alert(‘hello world’)</script> |
      | @$                                    |
      | !                                     |

  @tier2
  Scenario: Check a placeholder in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open search modal
    Then Placeholder contains "Search" text in search field

  @tier2
  Scenario: Check the possibility of editing data in search field in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open search modal
      And Type text "Book" and save it as 'word'
      And Edit data by adding characters in search field and save it as 'newWord'
    Then Placeholder contains word 'newWord' text in search field

  @tier2
  Scenario: Check of empty field in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open search modal
    Then There is no possibility to search with empty search field

  @tier2
  Scenario: Check of displaying the search field after search a book in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open search modal
      And Search for "Book" and save bookName as 'BookNameInfo'
    Then The search field is displayed and contains 'BookNameInfo' book

  @tier2
  Scenario Outline: Check that books from search result contain one or more entered latin letters or numeric in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Wait for 3 seconds
      And Open search modal
      And Search for word <word> and save as 'info' on Catalog books screen
    Then Books contain word 'info' on Catalog books screen

    Scenarios:
      | word         |
      | in           |
      | a            |
      | 0            |

  @tier2
  Scenario Outline: Find a book with name in different font cases in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open search modal
      And Search for word <word> and save as 'info' on Catalog books screen
    Then The first book has 'info' bookName on Catalog books screen

    Scenarios:
      |word       |
      | the silk road |
      | THE SILK ROAD |
      | ThE SiLk rOaD |

  @tier2
  Scenario Outline: Enter invalid data in book name in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Wait for 3 seconds
      And Open search modal
      And Search for word <data> and save as 'info' on Catalog books screen
    Then There is no results on Catalog books screen

    Scenarios:
      | data                                  |
      | рнл                                   |
      | <font color=red></font>               |
      | <script>alert(‘hello world’)</script> |
      | @$                                    |
      | !                                     |

  @tier2
  Scenario: Search: Perform check that the text field appears after clicking "Search" icon
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
    Then The search field is displayed

  @smoke
  Scenario: Search: Perform check that the field allows you to enter characters
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
    And Type text "book" and save it as 'bookInfo'
    Then Placeholder contains word 'bookInfo' text in search field

  @smoke
  Scenario: Search: Perform check of finding a book in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
      And Search for "An Open Web" and save bookName as 'bookNameInfo'
    Then EBOOK book with GET action button and 'bookNameInfo' bookName is displayed on Catalog books screen

  @smoke
  Scenario: Search: Perform check of the Delete button in Lyrasis Reads
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
      And Type text 'Silk Road' and save it as 'bookNameInfo'
      And Clear search field on Catalog books screen
    Then Search field is empty on Catalog books screen

  @smoke
  Scenario: Search: Perform check of finding a book in Palace Bookshelf
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
      And Search for 'El gato negro' and save bookName as 'bookNameInfo'
    Then EBOOK book with GET action button and 'bookNameInfo' bookName is displayed on Catalog books screen

  @smoke
  Scenario: Search: Perform check of the Delete button in Palace Bookshelf
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen
    When Open search modal
      And Type text 'El gato negro' and save it as 'bookNameInfo'
      And Clear search field on Catalog books screen
    Then Search field is empty on Catalog books screen