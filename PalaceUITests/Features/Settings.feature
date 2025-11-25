Feature: Check sections from settings screen

  @tier2
  Scenario: About Palace
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open Settings
      And Open About App on settings screen
    Then About App screen is opened

  @tier2
  Scenario: Privacy Policy
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open Settings
      And Open Privacy Policy on settings screen
    Then Privacy Policy screen is opened

  @tier2 @exclude_android
  Scenario: User Agreement
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open Settings
      And Open User Agreement on settings screen
    Then User Agreement screen is opened
    When Scroll page to link "www.copyright.gov" on user agreement screen
    Then Link "www.copyright.gov" is available on user agreement screen
    When Scroll page to link "http://thepalaceproject.org/licenses/" on user agreement screen
    Then Link "http://thepalaceproject.org/licenses/" is available on user agreement screen

  @tier2
  Scenario: Software Licenses
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Palace Bookshelf" on Add library screen
      And Open Settings
      And Open Software Licenses on settings screen
    Then Software Licenses screen is opened
    When Scroll page to link "www.apache.org/licenses" on software licenses screen
    Then Link "www.apache.org/licenses" is available on software licenses screen

  @tier2
  Scenario: Settings: User License Agreement
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open Settings
      And Open Libraries on Settings screen
      And Open 'Lyrasis Reads' library on Setting screen
      And Open User license agreement on account screen
    Then User License Agreement link is opened

  @logout @tier2 @exclude_android
  Scenario: Setting: Advanced
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Enter credentials for 'Lyrasis Reads' library
    Then Login is performed successfully
    When Open Settings
      And Open Libraries on Settings screen
      And Open 'Lyrasis Reads' library on Setting screen
    When Open Advanced on account screen
    Then Advanced screen contains "Delete Server Data" button
    When Click "Delete Server Data" button and cancel it on Advanced screen
    Then Advanced screen contains "Delete Server Data" button

  @smoke
  Scenario: Settings: Perform check of the Settings tab availability of required interface elements in Sign in screen
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open Settings
      And Open Libraries on Settings screen
      And Open "Lyrasis Reads" library on Setting screen
    Then Library "Lyrasis Reads" is opened on Account screen
      And All fields and links are displayed on Account screen
      And All fields and links are displayed on Sign in screen

  @smoke
  Scenario: Settings: Log in: Perform check of  the link Content Licenses
    When Close tutorial screen
    Then Add library screen is opened
    When Add library "Lyrasis Reads" on Add library screen
      And Open Settings
      And Open Libraries on Settings screen
      And Open 'Lyrasis Reads' library on Setting screen
      And Open Content Licenses on Account screen
    Then Content Licenses screen is opened