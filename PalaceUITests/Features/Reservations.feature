Feature: Reservation of book in LYRASIS

  @logout @returnBooks @tier1
  Scenario: Reserve from Subcategory List View and Remove a Reserved Book from Subcategory List View
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Bibliotheca' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Switch to 'eBooks' catalog tab
      And Click RESERVE action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click REMOVE action button on EBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then EBOOK book with RESERVE action button and 'bookInfo' bookInfo is present on Catalog books screen

  @logout @returnBooks @tier1
  Scenario: Reserve from Book Detail View and and Remove a Reserved Book from Reservations
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Palace Marketplace' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Switch to 'eBooks' catalog tab
    Then Subcategory screen is opened
    When Open EBOOK book with RESERVE action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then Book 'bookInfo' is opened on book details screen
    When Click RESERVE action button on Book details screen
      And Open Reservations
    Then EBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen
    When Open EBOOK book with REMOVE action button and 'bookInfo' bookInfo on Reservations screen
      And Click REMOVE action button on Book details screen
      And Open Reservations
      And Wait for 7 seconds
    Then EBOOK book with REMOVE action button and 'bookInfo' bookInfo is not present on Reservations screen

  @logout @returnBooks @tier1
  Scenario: Reserve from Book Detail View and Remove a Reserved Book from Book Detail View
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Palace Marketplace' and bookType 'AUDIOBOOK' and save as 'bookNameInfo'
      And Switch to 'Audiobooks' catalog tab
    Then Subcategory screen is opened
    When Open EBOOK book with RESERVE action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then Book 'bookInfo' is opened on book details screen
    When Click RESERVE action button on Book details screen
      And Click REMOVE action button on Book details screen
    Then Check that book contains RESERVE action button on Book details screen

  @logout @returnBooks @tier1 @exclude_android
  Scenario: Reserve from Book Detail View and Cancel remove from Reservations tab (IOS)
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Axis 360' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Switch to 'eBooks' catalog tab
      And Open EBOOK book with RESERVE action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then Book 'bookInfo' is opened on book details screen
    When Click RESERVE action button on Book details screen
    Then Check that book contains REMOVE action button on Book details screen
    When Click REMOVE action button on book details screen and click CANCEL action button on alert. Only for ios
    Then Check that book contains REMOVE action button on Book details screen
    When Open Reservations
    Then EBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen

  @logout @returnBooks @tier1 @exclude_ios
  Scenario: Check books sorting in Reservations
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Axis 360' and bookType 'AUDIOBOOK' and save as 'bookNameInfo'
      And Click RESERVE action button on AUDIOBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Palace Marketplace' and bookType 'AUDIOBOOK' and save as 'bookNameInfo2'
      And Click RESERVE action button on AUDIOBOOK book with 'bookNameInfo2' bookName on Catalog books screen and save book as 'bookInfo2'
      And Clear search field on Catalog books screen
      And Search 'unavailable' book of distributor 'Bibliotheca' and bookType 'AUDIOBOOK' and save as 'bookNameInfo3'
      And Click RESERVE action button on AUDIOBOOK book with 'bookNameInfo3' bookName on Catalog books screen and save book as 'bookInfo3'
      And Open Reservations
    Then Books are sorted by Title by default on Reservations screen
      And Books are sorted by Title ascending on Reservations screen
    When Sort books by AUTHOR in "Lyrasis Reads"
    Then Books are sorted by Author ascending on Reservations screen
      And There are sorting by 'Title' and 'Author' in 'Lyrasis Reads' on Reservations screen

  @logout @returnBooks @tier1 @exclude_android
  Scenario: Alert: Check of Cancel button after Remove button tapping
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Bibliotheca' and bookType 'EBOOK' and save as 'bookNameInfo'
      And Switch to 'eBooks' catalog tab
      And Open EBOOK book with RESERVE action button and 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
      And Click RESERVE action button on Book details screen
      And Open Reservations
    Then EBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen
    When Open EBOOK book with REMOVE action button and 'bookInfo' bookInfo on Reservations screen
      And Click REMOVE button but cancel the action by clicking CANCEL button on the alert
      And Open Reservations
    Then EBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen

  @smoke @logout @returnBooks
  Scenario: Reservations: Perform check of book appearance and remove it
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Palace Marketplace' and bookType 'AUDIOBOOK' and save as 'bookNameInfo'
      And Switch to 'Audiobooks' catalog tab
      And Click RESERVE action button on AUDIOBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open Reservations
    Then AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen
    When Open AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo on Reservations screen
      And Click REMOVE action button on Book details screen
      And Open Reservations
      And Wait for 7 seconds
    Then AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo is not present on Reservations screen

  @smoke @logout @returnBooks @exclude_android
  Scenario: Reservations: Perform check of Remove button and cancel removing
    When Close tutorial screen
    Then Welcome screen is opened
    When Close welcome screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
    Then Library "Lyrasis Reads" is opened on Catalog screen
    When Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Activate sync bookmarks on Sign in screen
      And Open Catalog
      And Open search modal
      And Search 'unavailable' book of distributor 'Palace Marketplace' and bookType 'AUDIOBOOK' and save as 'bookNameInfo'
      And Switch to 'Audiobooks' catalog tab
      And Click RESERVE action button on AUDIOBOOK book with 'bookNameInfo' bookName on Catalog books screen and save book as 'bookInfo'
    Then AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Catalog books screen
    When Open Reservations
    Then AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo is present on Reservations screen
    When Open AUDIOBOOK book with REMOVE action button and 'bookInfo' bookInfo on Reservations screen
      And Click REMOVE action button without closing alert on Book details screen
    Then There is an alert to remove reservations with REMOVE and CANCEL buttons
    When Tap CANCEL button on the alert
    Then Check that book contains REMOVE action button on Book details screen