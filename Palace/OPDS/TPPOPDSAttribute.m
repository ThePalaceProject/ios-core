BOOL TPPOPDSAttributeKeyStringIsActiveFacet(NSString *const string)
{
  return string != nil && [string rangeOfString:@"activeFacet"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;

}

BOOL TPPOPDSAttributeKeyStringIsFacetGroup(NSString *const string)
{
  return string != nil && [string rangeOfString:@"facetGroup"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;

}

BOOL TPPOPDSAttributeKeyStringIsFacetGroupType(NSString *const string)
{
  return string != nil && [string rangeOfString:@"facetGroupType"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}
