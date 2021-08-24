@objcMembers final class TPPFacetViewDefaultDataSource: NSObject, TPPFacetViewDataSource {

  let facetGroups: [TPPCatalogFacetGroup]

  required init(facetGroups: [TPPCatalogFacetGroup]) {
    self.facetGroups = facetGroups
  }

  //MARK: -

  func numberOfFacetGroups(in facetView: TPPFacetView!) -> UInt {
    return UInt(facetGroups.count)
  }

  func facetView(_ facetView: TPPFacetView!, numberOfFacetsInFacetGroupAt index: UInt) -> UInt {
    return UInt(self.facetGroups[Int(index)].facets.count)
  }

  func facetView(_ facetView: TPPFacetView!, nameForFacetGroupAt index: UInt) -> String! {
    return self.facetGroups[Int(index)].name
  }

  func facetView(_ facetView: TPPFacetView!, nameForFacetAt indexPath: IndexPath!) -> String! {
    let group = self.facetGroups[indexPath.section]
    let facet = group.facets[indexPath.row] as! TPPCatalogFacet
    return facet.title
  }

  func facetView(_ facetView: TPPFacetView!, isActiveFacetForFacetGroupAt index: UInt) -> Bool {
    let group = self.facetGroups[Int(index)]
    return group.facets.compactMap { $0 as? TPPCatalogFacet }
        .contains(where: { $0.active })
  }

  func facetView(_ facetView: TPPFacetView!, activeFacetIndexForFacetGroupAt index: UInt) -> UInt {
    let group = self.facetGroups[Int(index)]
    var index: UInt = 0
    for facet in group.facets as! [TPPCatalogFacet] {
      if facet.active {
        return index
      }
      index += 1
    }
    fatalError("InternalInconsistencyException")
  }
}
