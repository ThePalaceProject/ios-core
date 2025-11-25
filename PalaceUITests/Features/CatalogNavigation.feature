Feature: Catalog Navigation module

  Background:
    Given Close tutorial screen
    Then Add library screen is opened

  @tier2
  Scenario: Return to last library catalog
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
    When Add 'Lyrasis Reads' library in Libraries screen
    Then Catalog screen is opened
    When Restart app
    Then Catalog screen is opened
      And Category names are loaded on Catalog screen

  @tier2
  Scenario: Check of the titles of books sections in Palace Bookshelf
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
      And Catalog screen is opened
      And Category names are correct on Catalog screen

  @tier2
  Scenario Outline: Check of books sorting in Palace Bookshelf
    When Add library "Palace Bookshelf" on Add library screen
    Then Library "Palace Bookshelf" is opened on Catalog screen
      And Catalog screen is opened
    When Open categories by chain and chain starts from CategoryScreen:
      | DPLA Publications |
    Then Books are sorted by Author by default on subcategory screen in 'Palace Bookshelf'
      And There are sorting by '<type1>', '<type2>' and '<type3>' on Subcategory screen in 'Palace Bookshelf'

    Scenarios:
      | type1  | type2          | type3 |
      | Author | Recently Added | Title |

  @tier2
  Scenario Outline: Check of tabs at the top of the screen in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
      And There are types '<type1>', '<type2>' and '<type3>' of books on catalog book screen:
      And Section with books of '<type1>' type is opened on catalog book screen
    When Switch to '<type2>' catalog tab
    Then Section with books of '<type2>' type is opened on catalog book screen
    When Switch to '<type3>' catalog tab
    Then Section with books of '<type3>' type is opened on catalog book screen

    Scenarios:
      | type1 | type2  | type3      |
      | All   | eBooks | Audiobooks |

  @tier2
  Scenario: Check of the titles of books sections in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
      And Category names are correct on Catalog screen

  @tier2
  Scenario Outline: Check of books sorting in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
    When Open categories by chain and chain starts from CategoryScreen:
      | TEST Baker & Taylor |
      And Swipe sort options
    Then Books are sorted by Author by default on subcategory screen in 'Lyrasis Reads'
      And There are sorting by '<type1>', '<type2>' and '<type3>' on Subcategory screen in "Lyrasis Reads"

    Scenarios:
      | type1  | type2          | type3 |
      | Author | Recently Added | Title |

  @tier2
  Scenario Outline: Check of books availability in Lyrasis Reads
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
    When Open categories by chain and chain starts from CategoryScreen:
      | TEST Baker & Taylor |
    Then The book availability is ALL by default on Subcategory screen
      And There are availability by '<type1>', '<type2>' and '<type3>' on Subcategory screen

    Scenarios:
      | type1 | type2         | type3         |
      | All   | Available now | Yours to keep |

  @tier2
  Scenario: Check all types of availability
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
    When Open categories by chain and chain starts from CategoryScreen:
      | TEST Baker & Taylor |
    Then Subcategory name is 'TEST Baker & Taylor'
    When Change books visibility to show AVAILABLE_NOW
    Then All books can be loaned or downloaded
    When Change books visibility to show ALL
      And Change books visibility to show YOURS_TO_KEEP
    Then All books can be downloaded

  @tier2 @exclude_android
  Scenario Outline: Check of books collections
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
      And Catalog screen is opened
    When Open categories by chain and chain starts from CategoryScreen:
      | TEST Baker & Taylor |
    Then Collections is Everything by default on subcategory screen
    And There are collection type by '<type1>' and '<type2>' on subcategory screen

    Scenarios:
      | type1      | type2         |
      | Everything | Popular Books |