# Step Migration Mapping

**Your existing Appium steps → Swift Cucumberish implementations**

## 🔍 **Analysis of Your 197 Scenarios:**

### **Most Common Steps (Need Swift Implementation):**

1. `When Add library "<library>" on Add library screen` (102×)
2. `When Click READ action button on Book details screen` (77×)
3. `Then Library "<library>" is opened on Catalog screen` (76×)
4. `When Close tutorial screen` (56×)
5. `When Open search modal` (57×)
6. `When Search 'available' book of distributor '<dist>' and bookType '<type>' and save as '<var>'` (49×)
7. `When Click GET action button on EBOOK book with '<var>' bookName...` (49×)
8. `When Switch to '<tab>' catalog tab` (35×)
9. `When Open Books` (35×)
10. `When Click GET action button on Book details screen` (37×)

### **What I Created (57 steps) vs What You Need:**

**My Steps (Generic):**
- "When I search for 'Alice'" ← TOO SIMPLE
- "When I tap the GET button" ← TOO SIMPLE

**Your Steps (Specific, Parameterized):**
- "Search 'available' book of distributor 'Bibliotheca' and bookType 'EBOOK' and save as 'bookInfo'" ← COMPLEX
- "Click GET action button on EBOOK book with 'bookInfo' bookName on Catalog books screen and save book as 'fullBookInfo'" ← VERY COMPLEX

---

## 📋 **Migration Priority:**

### **Tier 1: Copy ALL Feature Files**
Let me copy all 21 .feature files to PalaceUITests/Features/

### **Tier 2: Create Top 50 Step Definitions**
Implement Swift for your most common steps

### **Tier 3: Run & Iterate**
Run tests, add missing steps as discovered

---

**Let me start by copying ALL your feature files and creating the step implementations!**
